import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_automix/models/alert_model.dart';
import 'package:smart_automix/models/device_model.dart';
import 'package:smart_automix/models/maintenance.dart';
import 'package:smart_automix/screens/maintenance/maintenance_screen.dart';
import 'package:smart_automix/services/alert_service.dart';
import 'package:smart_automix/services/device_service.dart';
import 'package:smart_automix/services/maintenance_service.dart';
import 'package:smart_automix/services/panel/mqtt_panel_link.dart';
import 'package:smart_automix/services/panel/panel_topics.dart';
import 'package:smart_automix/services/panel_service.dart';
import 'package:smart_automix/services/tariff_service.dart';

import 'services/panel/fake_mqtt_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final start = DateTime(2026, 10, 1, 8);
  MaintenanceTask task({int? hours, int? days, double doneAt = 100}) =>
      MaintenanceTask(
        id: 't1',
        machineId: 'mill',
        title: 'Grease the bearings',
        everyHours: hours,
        everyDays: days,
        doneAtHours: doneAt,
        doneOn: start,
      );

  group('MaintenanceTask', () {
    test('hours: soon at 90%, due at 100%', () {
      final t = task(hours: 200);
      expect(t.statusAt(250, start), TaskStatus.ok);
      expect(t.statusAt(280, start), TaskStatus.soon);
      expect(t.statusAt(300, start), TaskStatus.due);
      expect(t.dueText(258, start), 'due in 42 h');
      expect(t.dueText(312, start), 'overdue by 12 h');
    });

    test('days, and whichever comes first', () {
      final t = task(hours: 500, days: 30);
      final later = start.add(const Duration(days: 31));
      expect(t.statusAt(150, later), TaskStatus.due, reason: 'days first');
      expect(
          t.dueText(150, start.add(const Duration(days: 25))), 'due in 5 days');
      expect(t.intervalText, 'every 500 h or 30 days');
      expect(task(days: 1).intervalText, 'every 1 day');
    });

    test('JSON round trip', () {
      final t = task(hours: 200, days: 90);
      final copy = MaintenanceTask.fromJson(t.toJson())!;
      expect(copy.toJson(), t.toJson());
      expect(MaintenanceTask.fromJson({'id': 1}), isNull);
    });

    test('suggestions exist for the main machine types', () {
      for (final type in [
        'mill',
        'compressor',
        'welder',
        'pump',
        MaintenanceTask.generatorId
      ]) {
        expect(MaintenanceTask.suggestionsFor(type), isNotEmpty, reason: type);
      }
      expect(MaintenanceTask.suggestionsFor('lighting'), isEmpty);
    });
  });

  group('MaintenanceService', () {
    late DateTime now;
    late FakeMqttTransport transport;
    late PanelService panel;
    late DeviceService devices;
    late MaintenanceService maintenance;
    final topics = PanelTopics('panel-test');

    Future<void> setUpService({bool mqtt = false}) async {
      now = start;
      SharedPreferences.setMockInitialValues({
        if (mqtt) ...{'panel_mode': 'mqtt', 'panel_host': 'broker.test'},
        'devices': jsonEncode([
          DeviceModel(
                  id: 'mill',
                  name: 'Maize mill',
                  type: 'mill',
                  location: 'A',
                  isOn: true,
                  powerConsumption: 7500)
              .toJson(),
        ]),
      });
      FlutterSecureStorage.setMockInitialValues({});
      transport = FakeMqttTransport();
      panel = PanelService(
          linkFactory: mqtt
              ? (_) => MqttPanelLink(topics: topics, transport: transport)
              : PanelService.createLink);
      await panel.init();
      await Future<void>.delayed(Duration.zero);
      devices = DeviceService(TariffService(), panel: panel);
      await devices.init();
      maintenance = MaintenanceService(
          devices: devices,
          panel: panel,
          clock: () => now,
          tick: const Duration(hours: 1));
      await maintenance.init();
    }

    tearDown(() => maintenance.dispose());

    test('the app counts hours of a running machine it can see', () async {
      await setUpService(); // simulation: the states shown are real
      now = now.add(const Duration(hours: 3));
      maintenance.countAppHours();
      expect(maintenance.hoursOf('mill'), closeTo(3, 1e-9));
      expect(maintenance.countedByPanel('mill'), isFalse);
    });

    test("the panel's count wins, and the app stops counting", () async {
      await setUpService(mqtt: true);
      transport.deliver(topics.state('mill'), 'ON');
      transport.deliver(topics.status, 'online');
      transport.deliver(topics.hours('mill'), PanelTopics.encodeHours(720000));
      await Future<void>.delayed(Duration.zero);
      now = now.add(const Duration(hours: 3));
      maintenance.countAppHours();
      expect(maintenance.hoursOf('mill'), 200);
      expect(maintenance.countedByPanel('mill'), isTrue);
    });

    test('nothing is counted while the panel is unreachable', () async {
      await setUpService(mqtt: true); // connected, panel status unknown
      now = now.add(const Duration(hours: 3));
      maintenance.countAppHours();
      expect(maintenance.hoursOf('mill'), 0);
    });

    test('tasks fall due with hours and reset when done', () async {
      await setUpService();
      await maintenance.addTask(
          machineId: 'mill', title: 'Grease the bearings', everyHours: 2);
      now = now.add(const Duration(hours: 2));
      maintenance.countAppHours();
      expect(maintenance.dueTasks, hasLength(1));

      await maintenance.markDone(maintenance.tasks.single.id);
      expect(maintenance.dueTasks, isEmpty);
      expect(maintenance.tasks.single.doneAtHours, closeTo(2, 1e-9));
    });

    test('suggested tasks are added once', () async {
      await setUpService();
      await maintenance.addSuggested('mill', 'mill');
      await maintenance.addSuggested('mill', 'mill');
      expect(maintenance.tasksFor('mill'),
          hasLength(MaintenanceTask.suggestionsFor('mill').length));
    });

    test('a due task raises one alert, cleared when done', () async {
      await setUpService();
      final alerts = AlertService(devices, TariffService(),
          panel: panel, maintenance: maintenance);
      await maintenance.addTask(
          machineId: 'mill', title: 'Grease the bearings', everyHours: 1);
      now = now.add(const Duration(hours: 1));
      maintenance.countAppHours();
      await alerts.checkMaintenance();
      expect(alerts.alerts.single.title, 'Maintenance due: Maize mill');
      expect(alerts.alerts.single.severity, AlertSeverity.warning);

      await maintenance.markDone(maintenance.tasks.single.id);
      await alerts.checkMaintenance();
      expect(alerts.alerts, isEmpty);
    });
  });

  testWidgets('screen: hours, suggested tasks, and Done', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await deviceService.init(); // demo machines
    await maintenanceService.init();
    await tester.binding.setSurfaceSize(const Size(420, 3000));
    await tester.pumpWidget(const MaterialApp(home: MaintenanceScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Maize Mill Motor'), findsOneWidget);
    await tester.tap(find.textContaining('suggested').first);
    await tester.pumpAndSettle();
    expect(find.text('Done'), findsWidgets);

    await tester.tap(find.text('Done').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('marked done'), findsOneWidget);
    maintenanceService.dispose();
  });
}
