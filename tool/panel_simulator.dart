// Simulates a SMART-AUTOMIX switch panel controller over MQTT, so the app's
// MQTT mode can be demonstrated and tested without real relay hardware.
//
// It behaves like the firmware should: announces itself online (with an
// "offline" last will), listens for ON/OFF commands, and reports each
// machine's new state as a retained message.
//
// Usage:
//   dart run tool/panel_simulator.dart --panel <panel-id> [options]
//
// Options:
//   --host <host>       Broker host (default: broker.emqx.io)
//   --port <port>       Broker TCP port (default: 1883, or 8883 with --tls)
//   --tls               Connect with TLS
//   --user <name>       Broker username
//   --password <pw>     Broker password
//   --delay-ms <ms>     Relay switching delay before reporting (default 300)
//   --ignore <id,...>   Machine IDs whose commands are ignored, to see how
//                       the app handles an unresponsive relay
//
// The panel ID must match the one shown in the app under
// Settings > Network. Stop with Ctrl+C (the panel then reports offline).

import 'dart:async';
import 'dart:io';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:smart_automix/services/panel/panel_topics.dart';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  final panelId = options['panel'];
  if (panelId == null || !PanelTopics.isValidPanelId(panelId)) {
    stderr
        .writeln('Usage: dart run tool/panel_simulator.dart --panel <panel-id> '
            '[--host h] [--port p] [--tls] [--user u --password p] '
            '[--delay-ms 300] [--ignore id1,id2]');
    exitCode = 64;
    return;
  }

  final topics = PanelTopics(panelId);
  final tls = options.containsKey('tls');
  final host = options['host'] ?? 'broker.emqx.io';
  final port = int.tryParse(options['port'] ?? '') ?? (tls ? 8883 : 1883);
  final delay =
      Duration(milliseconds: int.tryParse(options['delay-ms'] ?? '') ?? 300);
  final ignored = (options['ignore'] ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet();

  final clientId = 'smartautomix-sim-$panelId';
  final client = MqttServerClient.withPort(host, clientId, port)
    ..secure = tls
    ..logging(on: false)
    ..setProtocolV311()
    ..keepAlivePeriod = 20
    ..autoReconnect = true
    ..onAutoReconnected = (() => _log('reconnected'))
    ..connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .withWillTopic(topics.status)
        .withWillMessage(PanelTopics.offline)
        .withWillQos(MqttQos.atLeastOnce)
        .withWillRetain()
        .startClean();

  void publish(String topic, String payload) {
    final builder = MqttClientPayloadBuilder()..addString(payload);
    client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!,
        retain: true);
  }

  _log('connecting to $host:$port${tls ? ' (TLS)' : ''} as panel "$panelId"…');
  try {
    await client.connect(options['user'], options['password']);
  } catch (e) {
    stderr.writeln('Could not connect: $e');
    exitCode = 1;
    return;
  }
  if (client.connectionStatus?.state != MqttConnectionState.connected) {
    stderr.writeln('Broker refused the connection: ${client.connectionStatus}');
    exitCode = 1;
    return;
  }

  client.subscribe(topics.allMachineCommands, MqttQos.atLeastOnce);
  publish(topics.status, PanelTopics.online);
  _log('online. Waiting for commands on ${topics.allMachineCommands}');
  if (ignored.isNotEmpty) _log('ignoring commands for: ${ignored.join(', ')}');

  client.updates!.listen((batch) {
    for (final received in batch) {
      final message = received.payload;
      if (message is! MqttPublishMessage) continue;
      final machineId = topics.machineIdFrom(received.topic, suffix: 'set');
      final payload =
          MqttPublishPayload.bytesToStringAsString(message.payload.message);
      final on = PanelTopics.parseSwitch(payload);
      if (machineId == null || on == null) continue;

      if (ignored.contains(machineId)) {
        _log(
            'machine $machineId: $payload received — ignored (simulated fault)');
        continue;
      }
      _log('machine $machineId: switching ${on ? 'ON' : 'OFF'}…');
      Timer(delay, () {
        publish(topics.state(machineId), on ? PanelTopics.on : PanelTopics.off);
        _log('machine $machineId: reported ${on ? 'ON' : 'OFF'}');
      });
    }
  });

  // Run until Ctrl+C.
  await ProcessSignal.sigint.watch().first;

  _log('going offline');
  publish(topics.status, PanelTopics.offline);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  client.disconnect();
  exit(0);
}

Map<String, String> _parseArgs(List<String> args) {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) continue;
    final key = arg.substring(2);
    final hasValue = i + 1 < args.length && !args[i + 1].startsWith('--');
    options[key] = hasValue ? args[++i] : 'true';
  }
  return options;
}

void _log(String message) {
  final time = DateTime.now().toIso8601String().substring(11, 19);
  stdout.writeln('[$time] $message');
}
