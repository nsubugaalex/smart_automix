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

    test('parses ON/OFF case-insensitively', () {
      expect(PanelTopics.parseSwitch('ON'), isTrue);
      expect(PanelTopics.parseSwitch(' off '), isFalse);
      expect(PanelTopics.parseSwitch('1'), isNull);
    });
  });

  test('connecting subscribes to panel status and machine states', () async {
    await link.connect();
    expect(link.status, PanelLinkStatus.connected);
    expect(transport.subscriptions,
        containsAll([topics.status, topics.allMachineStates]));
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
}
