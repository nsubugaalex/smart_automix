// Simulates a SMART-AUTOMIX switch panel controller over MQTT, so the app's
// MQTT mode can be demonstrated and tested without real relay hardware.
//
// It behaves like the firmware should: announces itself online (with an
// "offline" last will), listens for ON/OFF commands, and reports each
// machine's new state as a retained message. Every few seconds it also
// publishes each machine's power draw and a supply meter reading, with a
// little noise, as current sensors and an energy meter would.
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
//   --overload <id,...> Machine IDs that draw 3x their rated current while
//                       on (a jammed motor), to trigger overcurrent alerts
//   --interval-s <s>    Seconds between power/meter readings (default 5)
//   --meter-start <kwh> Starting meter register (default 48210)
//   --no-sensors        Don't publish power or meter readings
//
// Power readings use the ratings of the app's demo machines (IDs 1-6);
// any other machine ID is treated as a 1 kW single-phase load.
//
// The panel ID must match the one shown in the app under
// Settings > Network. Stop with Ctrl+C (the panel then reports offline).

import 'dart:async';
import 'dart:io';
import 'dart:math';

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
  final ignored = _idList(options['ignore']);
  final overloaded = _idList(options['overload']);
  final sensors = !options.containsKey('no-sensors');
  final interval =
      Duration(seconds: int.tryParse(options['interval-s'] ?? '') ?? 5);

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

  void publish(String topic, String payload, {bool retain = true}) {
    final builder = MqttClientPayloadBuilder()..addString(payload);
    client.publishMessage(topic,
        retain ? MqttQos.atLeastOnce : MqttQos.atMostOnce, builder.payload!,
        retain: retain);
  }

  // Machines currently switched on, seeded from our own retained state
  // reports so a restarted simulator carries on where it left off.
  final running = <String>{};
  final machineIds = {..._demoMachines.keys};

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
  client.subscribe(topics.allMachineStates, MqttQos.atLeastOnce);
  publish(topics.status, PanelTopics.online);
  _log('online. Waiting for commands on ${topics.allMachineCommands}');
  if (ignored.isNotEmpty) _log('ignoring commands for: ${ignored.join(', ')}');
  if (overloaded.isNotEmpty) {
    _log('simulating overcurrent on: ${overloaded.join(', ')}');
  }

  final meter =
      _Meter(kwh: double.tryParse(options['meter-start'] ?? '') ?? 48210.0);
  final random = Random();
  void publishReadings() {
    var total = _Meter.baseLoadWatts * _jitter(random);
    for (final id in machineIds) {
      final rating = _demoMachines[id] ?? const _Rating(1000, 230);
      final factor = !running.contains(id)
          ? 0.0
          : overloaded.contains(id)
              ? 3.0
              : _jitter(random) * 0.9; // machines rarely run at full rating
      final watts = rating.watts * factor;
      total += watts;
      publish(
          topics.power(id),
          PanelTopics.encodePower(
              watts: watts, amps: rating.ratedAmps * factor),
          retain: false);
    }
    meter.advance(total);
    publish(topics.meter, PanelTopics.encodeMeter(watts: total, kwh: meter.kwh),
        retain: false);
  }

  client.updates!.listen((batch) {
    for (final received in batch) {
      final message = received.payload;
      if (message is! MqttPublishMessage) continue;
      final payload =
          MqttPublishPayload.bytesToStringAsString(message.payload.message);
      final stateId = topics.machineIdFrom(received.topic, suffix: 'state');
      if (stateId != null) {
        final on = PanelTopics.parseSwitch(payload);
        if (on == null) continue;
        machineIds.add(stateId);
        on ? running.add(stateId) : running.remove(stateId);
        continue;
      }
      final machineId = topics.machineIdFrom(received.topic, suffix: 'set');
      final command = PanelTopics.parseCommand(payload);
      if (machineId == null || command == null) continue;
      machineIds.add(machineId);
      final on = command.on;

      // Like the firmware: a late ON is dropped, unconfirmed.
      if (command.isStaleAt(DateTime.now())) {
        _log('machine $machineId: ON sent at ${command.issuedAt!.toLocal()} '
            'arrived too late — ignored');
        continue;
      }

      if (ignored.contains(machineId)) {
        _log(
            'machine $machineId: ${on ? 'ON' : 'OFF'} received — ignored (simulated fault)');
        continue;
      }
      _log('machine $machineId: switching ${on ? 'ON' : 'OFF'}…');
      Timer(delay, () {
        on ? running.add(machineId) : running.remove(machineId);
        publish(topics.state(machineId), on ? PanelTopics.on : PanelTopics.off);
        // Like the firmware: report the new draw straight away.
        if (sensors) publishReadings();
        _log('machine $machineId: reported ${on ? 'ON' : 'OFF'}');
      });
    }
  });

  Timer? readings;
  if (sensors) {
    readings = Timer.periodic(interval, (_) => publishReadings());
    _log('publishing power and meter readings every ${interval.inSeconds}s');
  }

  // Run until Ctrl+C.
  await ProcessSignal.sigint.watch().first;
  readings?.cancel();

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

Set<String> _idList(String? value) => (value ?? '')
    .split(',')
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toSet();

/// A random factor of 0.95-1.05, like a real load wandering about.
double _jitter(Random random) => 0.95 + random.nextDouble() * 0.1;

/// Nameplate rating of a simulated machine.
class _Rating {
  const _Rating(this.watts, this.volts, {this.threePhase = false});

  /// Typical for the workshop's inductive loads.
  static const powerFactor = 0.85;

  final double watts;
  final double volts;
  final bool threePhase;

  /// Line current at full rated load.
  double get ratedAmps =>
      watts / ((threePhase ? 1.732 : 1.0) * volts * powerFactor);
}

/// Ratings of the app's demo machines, by machine ID.
const _demoMachines = {
  '1': _Rating(750, 230), // grinding machine
  '2': _Rating(2200, 230), // air compressor
  '3': _Rating(5500, 415, threePhase: true), // welding machine
  '4': _Rating(7500, 415, threePhase: true), // maize mill motor
  '5': _Rating(1100, 230), // borehole pump
  '6': _Rating(1800, 230), // cold room unit
};

/// The supply meter's cumulative kWh register.
class _Meter {
  _Meter({required this.kwh});

  /// Lighting, sockets and other loads the app doesn't switch.
  static const baseLoadWatts = 150.0;

  double kwh;
  DateTime _last = DateTime.now();

  void advance(double watts) {
    final now = DateTime.now();
    final hours = now.difference(_last).inMilliseconds / 3600000;
    kwh += watts * hours / 1000;
    _last = now;
  }
}
