import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_automix/models/device_model.dart';
import 'package:smart_automix/models/supply.dart';
import 'package:smart_automix/services/activity_log.dart';
import 'package:smart_automix/services/device_service.dart';
import 'package:smart_automix/services/operator_profile.dart';
import 'package:smart_automix/services/panel/mqtt_panel_link.dart';
import 'package:smart_automix/services/panel/panel_topics.dart';
import 'package:smart_automix/services/panel_service.dart';
import 'package:smart_automix/services/tariff_service.dart';

import 'panel/fake_mqtt_transport.dart';

/// The activity log fed by the app's real MQTT link, with a fake broker.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final topics = PanelTopics('panel-test');
  late FakeMqttTransport transport;
  late PanelService panel;
  late DeviceService devices;
  late OperatorProfile profile;
  late ActivityLog log;

  Future<void> setUpLog({Map<String, Object> stored = const {}}) async {
    SharedPreferences.setMockInitialValues({
      'panel_mode': 'mqtt',
      'panel_host': 'broker.test',
      'operator_name': 'Grace',
      'install_id': 'phone-a',
      'devices': jsonEncode([
        DeviceModel(
                id: 'pump',
                name: 'Pump',
                type: 'pump',
                location: 'B',
                powerConsumption: 1100)
            .toJson(),
      ]),
      ...stored,
    });
    FlutterSecureStorage.setMockInitialValues({});
    profile = OperatorProfile();
    await profile.init();
    transport = FakeMqttTransport();
    panel = PanelService(
      linkFactory: (_) => MqttPanelLink(
        topics: topics,
        transport: transport,
        sender: () => (by: profile.name, src: profile.installId),
      ),
    );
    await panel.init();
    await Future<void>.delayed(Duration.zero); // background connect
    devices = DeviceService(TariffService(),
        panel: panel, confirmTimeout: const Duration(milliseconds: 50));
    await devices.init();
    log = ActivityLog(
      devices: devices,
      panel: panel,
      profile: profile,
      explainWait: const Duration(milliseconds: 50),
    );
    await log.init();
  }

  var disposed = false;
  tearDown(() async {
    if (!disposed) log.dispose();
    disposed = false;
    // Let its final save land before the next test resets storage.
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  /// Wait (up to 2 s) until [done] holds.
  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 120));

  List<String> texts() => [for (final e in log.entries) e.text];

  void event(String on, String cause, {String by = '', String src = ''}) =>
      transport.deliver(
          topics.event('pump'),
          PanelTopics.encodeMachineEvent(
              on: on == 'true',
              cause: MachineEventCause.values
                  .firstWhere((c) => c.wireName == cause),
              by: by,
              src: src));

  test("this phone's command is logged once, with the operator's name",
      () async {
    await setUpLog();
    await devices.turnOnDevice('pump');
    final sent = PanelTopics.parseCommand(transport.published.single.payload)!;
    expect(sent.by, 'Grace');
    expect(sent.src, 'phone-a');

    transport.deliver(topics.state('pump'), 'ON');
    event('true', 'command', by: 'Grace', src: 'phone-a'); // the echo
    await settle();
    expect(texts(), ['Grace switched Pump ON']);
    expect(log.entries.single.kind, ActivityKind.command);
  });

  test("another phone's command names who did it", () async {
    await setUpLog();
    transport.deliver(topics.state('pump'), 'ON');
    event('true', 'command', by: 'Peter', src: 'phone-b');
    await settle();
    expect(texts(), ['Peter switched Pump ON']);
  });

  test('trips and switching at the panel say so', () async {
    await setUpLog();
    transport.deliver(topics.state('pump'), 'ON');
    event('true', 'panel');
    transport.deliver(topics.state('pump'), 'OFF');
    event('false', 'trip');
    await settle();
    expect(texts(), [
      'Pump stopped by itself: overload relay or emergency stop',
      'Pump switched ON at the panel',
    ]);
    expect(log.entries.first.kind, ActivityKind.fault);
  });

  test('a change the panel does not explain is still logged', () async {
    await setUpLog();
    transport.deliver(topics.state('pump'), 'ON'); // older firmware
    await settle();
    expect(texts(), ['Pump switched ON (at the panel or from another phone)']);
  });

  test('a command that is not confirmed is logged', () async {
    await setUpLog();
    await devices.turnOnDevice('pump');
    await until(() => log.entries.isNotEmpty);
    expect(texts().single, startsWith('Grace: Pump not confirmed.'));
    expect(log.entries.single.kind, ActivityKind.commandFailed);
  });

  test('supply faults are logged once, at their own time', () async {
    await setUpLog();
    final from = DateTime(2026, 10, 20, 10, 5);
    transport.deliver(
        topics.supplyEvents,
        PanelTopics.encodeSupplyEvents([
          SupplyEvent(
              kind: SupplyState.outage,
              phase: 1,
              from: from,
              to: from.add(const Duration(minutes: 35)),
              minVolts: 0,
              maxVolts: 0),
        ]));
    event('false', 'supply'); // per-machine echo: not logged again
    await settle();
    expect(texts(), ['Power cut for 35 min']);
    expect(log.entries.single.time, from);
  });

  test('kept across a restart, newest first, and copied as CSV', () async {
    await setUpLog();
    transport.deliver(topics.state('pump'), 'ON');
    event('true', 'command', by: 'Peter "P"', src: 'phone-b');
    await settle();
    log.dispose(); // saves straight away
    await Future<void>.delayed(Duration.zero);
    final stored =
        (await SharedPreferences.getInstance()).getString('activity_log')!;
    disposed = true;

    await setUpLog(stored: {'activity_log': stored});
    expect(texts(), ['Peter "P" switched Pump ON']);
    expect(log.toCsv(), contains('"Peter ""P"" switched Pump ON"'));
  });

  test('operator names are kept plain and short', () {
    expect(OperatorProfile.clean('  Gr"ace\\\n  '), 'Grace');
    expect(OperatorProfile.clean('x' * 40), hasLength(32));
  });
}
