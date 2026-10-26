import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_automix/models/device_model.dart';
import 'package:smart_automix/models/machine_health.dart';
import 'package:smart_automix/services/alert_service.dart';
import 'package:smart_automix/services/device_service.dart';
import 'package:smart_automix/services/machine_health_service.dart';
import 'package:smart_automix/services/panel_service.dart';
import 'package:smart_automix/services/tariff_service.dart';
import 'package:smart_automix/widgets/common/machine_health_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;
  late DeviceService devices;
  late MachineHealthService health;

  Future<void> setUpService({bool millOn = true}) async {
    now = DateTime(2026, 10, 1, 9);
    SharedPreferences.setMockInitialValues({
      'devices': jsonEncode([
        DeviceModel(
                id: 'mill',
                name: 'Maize mill',
                type: 'mill',
                location: 'A',
                isOn: millOn,
                powerConsumption: 7500,
                lastUsed: DateTime(2026, 10, 1, 8))
            .toJson(),
      ]),
    });
    devices = DeviceService(TariffService());
    await devices.init();
    health = MachineHealthService(
        devices: devices, panel: PanelService(), clock: () => now);
    await health.init();
  }

  var disposed = false;
  tearDown(() {
    if (!disposed) health.dispose();
    disposed = false;
  });

  /// [samples] readings of [amps] on each of [days] days from `now`.
  void run(int days, double amps, {int samples = 300}) {
    for (var d = 0; d < days; d++) {
      for (var i = 0; i < samples; i++) {
        health.addSample('mill', amps + (i % 5) * 0.1);
      }
      now = now.add(const Duration(days: 1));
    }
    health.addSample('mill', amps); // first sample of the next day
  }

  test('only real running current counts', () async {
    await setUpService(millOn: false);
    health.addSample('mill', 12); // machine off
    expect(health.daysOf('mill'), isEmpty);

    await setUpService();
    health.addSample('mill', 0.05); // idling / noise
    health.addSample('unknown', 12); // not a machine of this app
    expect(health.daysOf('mill'), isEmpty);

    now = DateTime(2026, 10, 1, 8, 0, 10); // 10 s after starting: inrush
    health.addSample('mill', 40);
    expect(health.daysOf('mill'), isEmpty);
    now = DateTime(2026, 10, 1, 9);
    health.addSample('mill', 12);
    expect(health.daysOf('mill').single.n, 1);
  });

  test('learns, then flags drift, and an alert follows', () async {
    await setUpService();
    run(6, 12);
    expect(health.statusOf('mill').isLearning, isFalse);
    expect(health.statusOf('mill').finding, isNull);

    run(3, 15.5); // about 28% more
    final s = health.statusOf('mill');
    expect(s.finding, HealthKind.high);
    expect(health.flagged, ['mill']);

    final alerts = AlertService(devices, TariffService(), health: health);
    await alerts.checkMachineHealth();
    expect(alerts.alerts.single.title, 'Unusual running: Maize mill');
    expect(alerts.alerts.single.message, contains('more current than usual'));
    expect(alerts.alerts.single.message, contains('hammers'));

    await health.relearn('mill');
    expect(health.statusOf('mill').isLearning, isTrue);
    await alerts.checkMachineHealth();
    expect(alerts.alerts, isEmpty, reason: 'relearned: alert cleared');
  });

  test('kept across a restart', () async {
    await setUpService();
    run(6, 12);
    health.dispose(); // saves
    await Future<void>.delayed(Duration.zero);
    final again = MachineHealthService(
        devices: devices, panel: PanelService(), clock: () => now);
    await again.init();
    expect(again.daysOf('mill'), hasLength(7));
    expect(again.statusOf('mill').isLearning, isFalse);
    health = again; // disposed by tearDown
  });

  testWidgets('view explains a drift in words, and relearns', (tester) async {
    await setUpService();
    run(6, 12);
    run(3, 15.5);
    await tester.binding.setSurfaceSize(const Size(420, 600));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: health,
          builder: (context, _) => MachineHealthView(
              machineId: 'mill', type: 'mill', service: health),
        ),
      ),
    ));
    expect(find.textContaining('more current than usual for 3 days'),
        findsOneWidget);
    expect(find.textContaining('blunt hammers'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);

    await tester.tap(find.text('Relearn normal'));
    await tester.pumpAndSettle();
    expect(find.textContaining('0 of 5 days of running'), findsOneWidget);

    // Let the snackbar finish, and stop the service's save timer, before
    // the test ends.
    await tester.pump(const Duration(seconds: 5));
    health.dispose();
    disposed = true;
  });
}
