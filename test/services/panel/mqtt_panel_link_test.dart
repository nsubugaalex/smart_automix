import 'package:flutter_test/flutter_test.dart';
import 'package:smart_automix/services/panel/mqtt_panel_link.dart';
import 'package:smart_automix/services/panel/panel_link.dart';
import 'package:smart_automix/services/panel/panel_topics.dart';

import 'fake_mqtt_transport.dart';

void main() {
  final topics = PanelTopics('panel-test');
  late FakeMqttTransport transport;
  late MqttPanelLink link;

  setUp(() {
    transport = FakeMqttTransport();
    link = MqttPanelLink(topics: topics, transport: transport);
  });

  tearDown(() => link.dispose());

  group('PanelTopics', () {
    test('builds the documented topics', () {
      expect(topics.command('7'), 'smartautomix/panel-test/machines/7/set');
      expect(topics.state('7'), 'smartautomix/panel-test/machines/7/state');
      expect(topics.status, 'smartautomix/panel-test/status');
      expect(
          topics.allMachineStates, 'smartautomix/panel-test/machines/+/state');
    });

    test('extracts machine IDs only from matching topics', () {
      expect(topics.machineIdFrom(topics.state('42'), suffix: 'state'), '42');
      expect(
          topics.machineIdFrom(topics.command('42'), suffix: 'state'), isNull);
      expect(
          topics.machineIdFrom('smartautomix/other-panel/machines/42/state',
              suffix: 'state'),
          isNull);
      expect(
          topics.machineIdFrom('smartautomix/panel-test/machines/a/b/state',
              suffix: 'state'),
          isNull);
    });

    test('rejects panel IDs that would break the topic structure', () {
      expect(PanelTopics.isValidPanelId('panel-1a2b'), isTrue);
      expect(PanelTopics.isValidPanelId('a/b'), isFalse);
      expect(PanelTopics.isValidPanelId('a+b'), isFalse);
      expect(PanelTopics.isValidPanelId('#'), isFalse);
      expect(() => PanelTopics('bad/id'), throwsArgumentError);
    });

    test('builds the sensor topics', () {
      expect(topics.power('7'), 'smartautomix/panel-test/machines/7/power');
      expect(topics.meter, 'smartautomix/panel-test/meter');
      expect(
          topics.allMachinePower, 'smartautomix/panel-test/machines/+/power');
    });

    test('parses power and meter payloads, rejecting bad values', () {
      expect(PanelTopics.parsePower('{"w": 7100, "a": 12.4}'),
          (watts: 7100.0, amps: 12.4));
      expect(PanelTopics.parseMeter('{"w": 0, "kwh": 48211.7}'),
          (watts: 0.0, kwh: 48211.7));
      for (final bad in [
        '{"w": 7100}',
        '{"w": -1, "a": 2}',
        '{"w": "7100", "a": 2}',
        '[1, 2]',
        'ON',
      ]) {
        expect(PanelTopics.parsePower(bad), isNull, reason: bad);
      }
      expect(PanelTopics.parseMeter('{"w": 100}'), isNull);
    });

    test('encoded readings parse back', () {
      final power = PanelTopics.encodePower(watts: 812.345, amps: 3.4567);
      expect(PanelTopics.parsePower(power), (watts: 812.3, amps: 3.46));
      final meter = PanelTopics.encodeMeter(watts: 950, kwh: 48210.12345);
      expect(PanelTopics.parseMeter(meter), (watts: 950.0, kwh: 48210.123));
    });

    test('parses ON/OFF case-insensitively', () {
      expect(PanelTopics.parseSwitch('ON'), isTrue);
      expect(PanelTopics.parseSwitch(' off '), isFalse);
      expect(PanelTopics.parseSwitch('1'), isNull);
    });
  });

  test('connecting subscribes to panel status, states and sensors', () async {
    await link.connect();
    expect(link.status, PanelLinkStatus.connected);
    expect(
        transport.subscriptions,
        containsAll([
          topics.status,
          topics.allMachineStates,
          topics.allMachinePower,
          topics.meter,
        ]));
    expect(link.panelOnline, isNull); // until the panel reports in
  });

  test('a failed connection is reported with a readable reason', () async {
    transport.failConnect = true;
    await link.connect();
    expect(link.status, PanelLinkStatus.disconnected);
    expect(link.lastError, contains('Could not reach the broker'));
    expect(await link.sendCommand('1', on: true), isFalse);
  });

  test('commands are published as ON/OFF on the machine command topic',
      () async {
    await link.connect();
    expect(await link.sendCommand('3', on: true), isTrue);
    expect(await link.sendCommand('3', on: false), isTrue);
    expect(transport.published.map((m) => '${m.topic} ${m.payload}'), [
      '${topics.command('3')} ON',
      '${topics.command('3')} OFF',
    ]);
  });

  test('panel state and status messages are turned into reports', () async {
    await link.connect();
    final reports = <String>[];
    link.stateReports.listen((r) => reports.add('${r.machineId}=${r.isOn}'));

    transport
      ..deliver(topics.status, 'online')
      ..deliver(topics.state('1'), 'ON')
      ..deliver(topics.state('2'), 'off')
      ..deliver(topics.state('3'), 'garbage');
    await Future<void>.delayed(Duration.zero);

    expect(link.panelOnline, isTrue);
    expect(reports, ['1=true', '2=false']);

    transport.deliver(topics.status, 'offline');
    expect(link.panelOnline, isFalse);
  });

  test('a dropped connection shows as reconnecting and panel status unknown',
      () async {
    await link.connect();
    transport.deliver(topics.status, 'online');

    transport.setConnected(false);
    expect(link.status, PanelLinkStatus.connecting);
    expect(link.panelOnline, isNull);
    expect(await link.sendCommand('1', on: false), isFalse);

    transport.setConnected(true);
    expect(link.status, PanelLinkStatus.connected);
  });

  test('power and meter messages become telemetry; bad ones are dropped',
      () async {
    await link.connect();
    final readings = <String>[];
    link.telemetry.listen((t) => readings.add(switch (t) {
          MachinePowerReport() => '${t.machineId}:${t.watts}W/${t.amps}A',
          MeterReport() => 'meter:${t.watts}W/${t.kwh}kWh',
        }));

    transport
      ..deliver(topics.power('4'), '{"w": 6800, "a": 11.2}')
      ..deliver(topics.power('5'), 'garbage')
      ..deliver(topics.meter, '{"w": 9000, "kwh": 48211.5}');
    await Future<void>.delayed(Duration.zero);

    expect(readings, ['4:6800.0W/11.2A', 'meter:9000.0W/48211.5kWh']);
  });
}
