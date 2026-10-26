import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_automix/models/alert_model.dart';
import 'package:smart_automix/models/supply.dart';
import 'package:smart_automix/services/alert_service.dart';
import 'package:smart_automix/services/device_service.dart';
import 'package:smart_automix/services/panel/panel_link.dart';
import 'package:smart_automix/services/panel/panel_topics.dart';
import 'package:smart_automix/services/power_monitor.dart';
import 'package:smart_automix/services/tariff_service.dart';
import 'package:smart_automix/widgets/common/supply_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final from = DateTime(2026, 10, 20, 10, 5);
  SupplyEvent event(SupplyState kind,
          {DateTime? start, DateTime? end, int phase = 2}) =>
      SupplyEvent(
        kind: kind,
        phase: phase,
        from: start ?? from,
        to: end,
        minVolts: 183.4,
        maxVolts: 231,
      );

  group('protocol', () {
    test('supply state and events round trip', () {
      final state = PanelTopics.parseSupply(
          PanelTopics.encodeSupply(SupplyState.phaseLoss, since: from))!;
      expect(state.state, SupplyState.phaseLoss);
      expect(state.since, from);
      expect(PanelTopics.parseSupply('{"state": "bogus"}'), isNull);

      final events =
          PanelTopics.parseSupplyEvents(PanelTopics.encodeSupplyEvents([
        event(SupplyState.undervoltage,
            end: from.add(const Duration(minutes: 12))),
        event(SupplyState.outage),
      ]))!;
      expect(events, hasLength(2));
      expect(events[0].kind, SupplyState.undervoltage);
      expect(events[0].duration, const Duration(minutes: 12));
      expect(events[1].isOngoing, isTrue);
      expect(PanelTopics.parseSupplyEvents('{}'), isNull);
    });

    test('meter voltages, with a dead phase', () {
      expect(
          PanelTopics.parseMeterVolts(
              '{"w": 1, "kwh": 2, "v": [231.5, null, 229]}'),
          [231.5, null, 229.0]);
      expect(PanelTopics.parseMeterVolts('{"w": 1, "kwh": 2}'), isNull);
    });
  });

  test('event summaries and durations read naturally', () {
    expect(event(SupplyState.undervoltage).summary,
        'Low voltage on phase 2 (lowest 183 V)');
    expect(event(SupplyState.phaseLoss).summary, 'Phase 2 lost');
    expect(event(SupplyState.outage).summary, 'Power cut');
    expect(formatDuration(const Duration(minutes: 65)), '1 h 5 min');
    expect(formatDuration(const Duration(minutes: 35)), '35 min');
    expect(formatDuration(const Duration(seconds: 40)), '40 s');
  });

  group('PowerMonitor supply', () {
    late StreamController<PanelTelemetry> telemetry;
    late PowerMonitor monitor;
    late List<SupplyEventChange> changes;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      telemetry = StreamController<PanelTelemetry>.broadcast(sync: true);
      monitor = PowerMonitor(telemetry.stream);
      await monitor.init();
      changes = [];
      monitor.supplyEventChanges.listen(changes.add);
    });

    tearDown(() {
      monitor.dispose();
      telemetry.close();
    });

    test('tracks the supply state', () {
      telemetry.add(SupplyStatusReport(state: SupplyState.outage, since: from));
      expect(monitor.supplyState, SupplyState.outage);
      expect(monitor.supplySince, from);
    });

    test('reports new events once, and when they end', () async {
      final ongoing = event(SupplyState.undervoltage);
      telemetry.add(SupplyEventsReport([ongoing]));
      telemetry.add(SupplyEventsReport([ongoing])); // resent on reconnect
      await Future<void>.delayed(Duration.zero);
      expect(changes.map((c) => c.isNew), [true]);

      final ended = event(SupplyState.undervoltage,
          end: from.add(const Duration(minutes: 3)));
      telemetry.add(SupplyEventsReport([ended]));
      await Future<void>.delayed(Duration.zero);
      expect(changes.map((c) => c.isNew), [true, false]);
      expect(monitor.supplyEvents.single.isOngoing, isFalse);
    });

    test('keeps the log across a restart, newest first', () async {
      telemetry.add(SupplyEventsReport([
        event(SupplyState.outage, end: from.add(const Duration(hours: 1))),
        event(SupplyState.phaseLoss,
            start: from.add(const Duration(days: 1)),
            end: from.add(const Duration(days: 1, minutes: 2))),
      ]));
      await Future<void>.delayed(Duration.zero);
      final restarted = PowerMonitor(telemetry.stream);
      await restarted.init();
      expect(restarted.supplyEvents.map((e) => e.kind),
          [SupplyState.phaseLoss, SupplyState.outage]);
      restarted.dispose();
    });
  });

  group('alerts', () {
    late AlertService alerts;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      alerts = AlertService(DeviceService(TariffService()), TariffService());
    });

    Future<List<AlertModel>> after(SupplyEventChange change) async {
      alerts.onSupplyEvent(change);
      await Future<void>.delayed(Duration.zero);
      return alerts.alerts;
    }

    test('a fault going on now is critical', () async {
      final now = DateTime.now();
      final list = await after(SupplyEventChange(
          event(SupplyState.phaseLoss, start: now),
          isNew: true));
      expect(list.single.title, 'Supply fault: Phase lost');
      expect(list.single.severity, AlertSeverity.critical);
    });

    test('its end is a note that machines stayed off', () async {
      final now = DateTime.now();
      final list = await after(SupplyEventChange(
          event(SupplyState.undervoltage,
              start: now.subtract(const Duration(minutes: 7)), end: now),
          isNew: false));
      expect(list.single.title, 'Supply back to normal');
      expect(list.single.message, contains('for 7 min'));
      expect(list.single.message, contains('stay off'));
    });

    test('a recent one missed while closed is reported; old history is not',
        () async {
      final now = DateTime.now();
      var list = await after(SupplyEventChange(
          event(SupplyState.outage,
              start: now.subtract(const Duration(hours: 2)),
              end: now.subtract(const Duration(hours: 1))),
          isNew: true));
      expect(list.single.title, 'Power cut while the app was closed');

      list = await after(SupplyEventChange(
          event(SupplyState.outage,
              start: now.subtract(const Duration(days: 9)),
              end: now.subtract(const Duration(days: 9))),
          isNew: true));
      expect(list, hasLength(1), reason: 'nine-day-old cut: no alert');
    });
  });

  group('Supply card', () {
    testWidgets('shows the state, voltages, 30-day count and the log',
        (tester) async {
      final now = DateTime(2026, 10, 22, 12);
      await tester.binding.setSurfaceSize(const Size(420, 1000));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SupplyCard(
              state: SupplyState.ok,
              volts: const [231.4, 229.6, 230.2],
              events: [
                event(SupplyState.outage,
                    start: DateTime(2026, 10, 21, 9),
                    end: DateTime(2026, 10, 21, 10, 30)),
                event(SupplyState.undervoltage,
                    start: DateTime(2026, 10, 18, 14),
                    end: DateTime(2026, 10, 18, 14, 20)),
              ],
              now: now,
            ),
          ),
        ),
      ));
      expect(find.text(formatPhaseVolts(const [231.4, 229.6, 230.2])),
          findsOneWidget);
      expect(formatPhaseVolts(const [231.4, null]), 'L1 231 V · L2 no reading');
      expect(find.textContaining('1 power cut (1 h 30 min without power)'),
          findsOneWidget);
      expect(find.textContaining('1 voltage or phase fault'), findsOneWidget);
      expect(
          find.text('Low voltage on phase 2 (lowest 183 V)'), findsOneWidget);
    });

    test('CSV lists events oldest first', () {
      final csv = SupplyCard.csv([
        event(SupplyState.outage,
            start: DateTime(2026, 10, 21, 9),
            end: DateTime(2026, 10, 21, 10, 30)),
        event(SupplyState.undervoltage,
            start: DateTime(2026, 10, 18, 14),
            end: DateTime(2026, 10, 18, 14, 20)),
      ]);
      expect(
          csv,
          'kind,phase,from,to,minutes,min_volts,max_volts\n'
          'undervoltage,2,2026-10-18 14:00,2026-10-18 14:20,20,183,231\n'
          'outage,2,2026-10-21 09:00,2026-10-21 10:30,90,183,231\n');
    });
  });
}
