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
                powerConsumption: 1100,
                breakerRatingAmps: 10)
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

  group('sensor readings', () {
    Future<void> deliver(String topic, String payload) async {
      transport.deliver(topic, payload);
      await Future<void>.delayed(Duration.zero);
    }

    test('measured machine readings replace nameplate estimates', () async {
      await setUpPanel();
      final mill = devices.getDeviceById('mill')!;
      expect(devices.loadSource, LoadSource.estimated);
      expect(devices.loadOf(mill).isMeasured, isFalse);
      expect(devices.totalPowerConsumption, 7500);

      await deliver(topics.power('mill'), '{"w": 6800, "a": 11}');
      expect(devices.loadSource, LoadSource.partlyMeasured);
      await deliver(topics.power('pump'), '{"w": 0, "a": 0}');
      expect(devices.loadSource, LoadSource.measured);

      final load = devices.loadOf(mill);
      expect(load.isMeasured, isTrue);
      expect(load.amps, 11);
      expect(load.kva, closeTo(230 * 11 / 1000, 1e-9));
      expect(devices.totalPowerConsumption, 6800);
    });

    test('the supply meter gives the total and the energy used today',
        () async {
      await setUpPanel();
      await deliver(topics.meter, '{"w": 9100, "kwh": 48210}');
      expect(devices.totalPowerConsumption, 9100,
          reason: 'the meter also sees loads the app does not switch');
      expect(devices.loadSource, LoadSource.partlyMeasured);

      await deliver(topics.meter, '{"w": 9100, "kwh": 48212.5}');
      expect(devices.meteredEnergyTodayKwh, closeTo(2.5, 1e-9));
      expect(devices.meteredCostTodayUgx, greaterThan(0));
    });

    test('a measured current over the breaker rating counts as overloaded',
        () async {
      await setUpPanel();
      expect(devices.getOverloadedDevices(), isEmpty);

      await deliver(topics.power('pump'), '{"w": 3000, "a": 16.5}');
      expect(
          devices.getMeasuredOvercurrentDevices().map((d) => d.id), ['pump']);
      expect(devices.getOverloadedDevices().map((d) => d.id), ['pump']);
    });
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

    test('a measured overcurrent raises one alert per occurrence', () async {
      Future<void> pumpAmps(double amps) async {
        transport.deliver(topics.power('pump'), '{"w": 2000, "a": $amps}');
        await Future<void>.delayed(Duration.zero);
      }

      await pumpAmps(16);
      await pumpAmps(17);
      expect(titles().where((t) => t == 'Overcurrent: Pump'), hasLength(1));
      expect(alerts.alerts.first.message, contains('16.0 A on a 10 A breaker'));

      await pumpAmps(5);
      await pumpAmps(15);
      expect(titles().where((t) => t == 'Overcurrent: Pump'), hasLength(2));
    });

    test('an unconfirmed command is recorded as an alert', () async {
      await devices.turnOnDevice('pump');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(titles(), contains('Command not confirmed: Pump'));
    });
  });
}
