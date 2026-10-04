import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_automix/models/device_model.dart';
import 'package:smart_automix/services/alert_service.dart';
import 'package:smart_automix/services/device_service.dart';
import 'package:smart_automix/services/panel/mqtt_panel_link.dart';
import 'package:smart_automix/services/panel/panel_topics.dart';
import 'package:smart_automix/services/panel_service.dart';
import 'package:smart_automix/services/tariff_service.dart';

import 'fake_mqtt_transport.dart';

/// Machine control end-to-end through PanelService and MqttPanelLink,
/// with a fake broker standing in for the network.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final topics = PanelTopics('panel-test');
  late FakeMqttTransport transport;
  late PanelService panel;
  late DeviceService devices;
  late List<CommandFailure> failures;

  Future<void> setUpPanel({bool brokerDown = false}) async {
    SharedPreferences.setMockInitialValues({
      'panel_mode': 'mqtt',
      'panel_host': 'broker.test',
      'devices': jsonEncode([
        DeviceModel(
                id: 'mill',
                name: 'Mill',
                type: 'mill',
                location: 'A',
                isOn: true,
                powerConsumption: 7500)
            .toJson(),
        DeviceModel(
                id: 'pump',
                name: 'Pump',
                type: 'pump',
                location: 'B',
                powerConsumption: 1100)
            .toJson(),
      ]),
    });
    FlutterSecureStorage.setMockInitialValues({});
    transport = FakeMqttTransport(failConnect: brokerDown);
    panel = PanelService(
      linkFactory: (_) => MqttPanelLink(topics: topics, transport: transport),
    );
    await panel.init();
    await Future<void>.delayed(Duration.zero); // background connect
    devices = DeviceService(TariffService(),
        panel: panel, confirmTimeout: const Duration(milliseconds: 50));
    await devices.init();
    failures = [];
    devices.commandFailures.listen(failures.add);
  }

  bool isOn(String id) => devices.getDeviceById(id)!.isOn;

  test('a machine only switches when the panel confirms it', () async {
    await setUpPanel();

    await devices.toggleDevice('pump');
    expect(transport.published.single.topic, topics.command('pump'));
    expect(transport.published.single.payload, 'ON');
    expect(isOn('pump'), isFalse, reason: 'not confirmed yet');
    expect(devices.isAwaitingConfirmation('pump'), isTrue);

    transport.deliver(topics.state('pump'), 'ON');
    await Future<void>.delayed(Duration.zero);
    expect(isOn('pump'), isTrue);
    expect(devices.isAwaitingConfirmation('pump'), isFalse);
    expect(failures, isEmpty);
  });

  test('an unconfirmed command times out with a failure, state unchanged',
      () async {
    await setUpPanel();

    await devices.turnOffDevice('mill');
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(isOn('mill'), isTrue);
    expect(devices.isAwaitingConfirmation('mill'), isFalse);
    expect(failures.single.machineName, 'Mill');
    expect(failures.single.reason, contains('did not confirm'));
  });

  test('commands fail immediately when the broker is unreachable', () async {
    await setUpPanel(brokerDown: true);

    await devices.turnOnDevice('pump');
    await Future<void>.delayed(Duration.zero);
    expect(transport.published, isEmpty);
    expect(isOn('pump'), isFalse);
    expect(failures.single.reason, contains('Not connected'));
  });

  test('changes reported by the panel (e.g. switched on site) are shown',
      () async {
    await setUpPanel();
    transport.deliver(topics.state('mill'), 'OFF');
    await Future<void>.delayed(Duration.zero);
    expect(isOn('mill'), isFalse);
  });

  test('Cut All sends OFF to every running machine', () async {
    await setUpPanel();
    transport.deliver(topics.state('pump'), 'ON');
    await Future<void>.delayed(Duration.zero);

    await devices.turnOffAllDevices();
    expect(
      transport.published.map((m) => '${m.topic} ${m.payload}'),
      unorderedEquals(
          ['${topics.command('mill')} OFF', '${topics.command('pump')} OFF']),
    );
  });

  group('alerts', () {
    late AlertService alerts;

    setUp(() async {
      await setUpPanel();
      alerts = AlertService(devices, TariffService(), panel: panel);
      await alerts.init();
    });

    Iterable<String> titles() => alerts.alerts.map((a) => a.title);

    test('panel going offline raises an alert that clears when it returns',
        () async {
      transport.deliver(topics.status, 'offline');
      await Future<void>.delayed(Duration.zero);
      expect(titles(), contains('Switch panel unreachable'));

      transport.deliver(topics.status, 'online');
      await Future<void>.delayed(Duration.zero);
      expect(titles(), isNot(contains('Switch panel unreachable')));
    });

    test('an unconfirmed command is recorded as an alert', () async {
      await devices.turnOnDevice('pump');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(titles(), contains('Command not confirmed: Pump'));
    });
  });
}
