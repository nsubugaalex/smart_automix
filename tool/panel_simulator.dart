// Simulates a SMART-AUTOMIX switch panel controller over MQTT, so the app's
// MQTT mode can be demonstrated and tested without real relay hardware.
//
// It behaves like the firmware should: announces itself online (with an
// "offline" last will), listens for ON/OFF commands, and reports each
// machine's new state as a retained message. Every few seconds it also
// publishes each machine's power draw and a supply meter reading, with a
// little noise, as current sensors and an energy meter would, and today's
// energy total (retained, like the firmware's daily totals).
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
//   --history-days <n>  Also publish made-up daily energy totals for the
//                       last n days, to fill the app's history chart
//   --supply-fault <kind>:<start>:<length>  Simulate a supply fault
//                       (undervoltage, overvoltage, phase_loss or outage)
//                       starting <start> s after launch, lasting <length> s,
//                       to see supply protection switch machines off
//   --trip-delay-s <s>  How long a fault must last before tripping (default 5)
//   --stable-s <s>      How long the supply must be steady before starts
//                       are allowed again (default 60)
//   --generator-hours <a-b>  Run on the standby generator from hour a to
//                       hour b (local time, e.g. 19-22), like an evening
//                       outage; history days get some generator use too
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
import 'package:smart_automix/models/supply.dart';
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

  // Why a machine changed, like the firmware's event messages.
  void publishEvent(String id, bool on, MachineEventCause cause,
          {String by = '', String src = ''}) =>
      publish(
          topics.event(id),
          PanelTopics.encodeMachineEvent(
              on: on, cause: cause, by: by, src: src),
          retain: false);

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

  // Supply protection, like the firmware: trip after the fault has lasted
  // tripDelay, allow starts again once the supply has been steady for
  // stable. Never restarts machines.
  final fault = _parseFault(options['supply-fault']);
  final started = DateTime.now();
  final tripDelay =
      Duration(seconds: int.tryParse(options['trip-delay-s'] ?? '') ?? 5);
  final stable =
      Duration(seconds: int.tryParse(options['stable-s'] ?? '') ?? 60);
  var supply = SupplyState.ok;
  SupplyState? pendingFault;
  DateTime? faultSince, okSince;
  final supplyEvents = <SupplyEvent>[];

  void publishSupply() => publish(
      topics.supply, PanelTopics.encodeSupply(supply, since: DateTime.now()));
  void publishSupplyEvents() => publish(
      topics.supplyEvents, PanelTopics.encodeSupplyEvents(supplyEvents));

  List<double?> phaseVolts(DateTime now) {
    double normal() => 228 + random.nextDouble() * 6;
    final elapsed = now.difference(started);
    final active = fault != null &&
        elapsed >= fault.start &&
        elapsed < fault.start + fault.length;
    if (!active) return [normal(), normal(), normal()];
    return switch (fault.kind) {
      SupplyState.undervoltage => [
          normal(),
          180 + random.nextDouble() * 4,
          normal()
        ],
      SupplyState.overvoltage => [
          normal(),
          normal(),
          262 + random.nextDouble() * 4
        ],
      SupplyState.phaseLoss => [normal(), normal(), null],
      _ => [null, null, null],
    };
  }

  SupplyState classify(List<double?> v) {
    final live = v.where((x) => x != null && x >= 100).length;
    if (live == 0) return SupplyState.outage;
    if (v.any((x) => x == null || x < 100)) return SupplyState.phaseLoss;
    if (v.any((x) => x! < 200)) return SupplyState.undervoltage;
    if (v.any((x) => x! > 255)) return SupplyState.overvoltage;
    return SupplyState.ok;
  }

  int faultPhase(List<double?> v, SupplyState kind) {
    for (var i = 0; i < v.length; i++) {
      final x = v[i];
      final bad = switch (kind) {
        SupplyState.undervoltage => x != null && x < 200,
        SupplyState.overvoltage => x != null && x > 255,
        _ => x == null || x < 100,
      };
      if (bad) return i + 1;
    }
    return 1;
  }

  void checkSupply(List<double?> volts, DateTime now) {
    final seen = classify(volts);
    if (seen != SupplyState.ok) {
      okSince = null;
      if (supply.isFault) {
        final e = supplyEvents.last;
        final v = volts[e.phase - 1] ?? 0;
        supplyEvents.last = SupplyEvent(
            kind: e.kind,
            phase: e.phase,
            from: e.from,
            to: null,
            minVolts: min(e.minVolts, v),
            maxVolts: max(e.maxVolts, v));
        return;
      }
      if (pendingFault != seen) {
        pendingFault = seen;
        faultSince = now;
        return;
      }
      if (now.difference(faultSince!) < tripDelay) return;
      supply = seen;
      final phase = faultPhase(volts, seen);
      final v = volts[phase - 1] ?? 0;
      supplyEvents.add(SupplyEvent(
          kind: seen,
          phase: phase,
          from: now,
          to: null,
          minVolts: v,
          maxVolts: v));
      if (supplyEvents.length > 16) supplyEvents.removeAt(0);
      for (final id in running.toList()) {
        running.remove(id);
        publish(topics.state(id), PanelTopics.off);
        publishEvent(id, false, MachineEventCause.supply);
      }
      _log('SUPPLY FAULT: ${seen.wireName} on phase $phase, all machines '
          'switched off');
      publishSupply();
      publishSupplyEvents();
      return;
    }
    pendingFault = null;
    if (supply.isFault) {
      final e = supplyEvents.last;
      supplyEvents.last = SupplyEvent(
          kind: e.kind,
          phase: e.phase,
          from: e.from,
          to: now,
          minVolts: e.minVolts,
          maxVolts: e.maxVolts);
      supply = SupplyState.settling;
      okSince = now;
      _log('supply back in range; starts allowed once it has been steady');
      publishSupply();
      publishSupplyEvents();
    } else if (supply == SupplyState.settling &&
        now.difference(okSince!) >= stable) {
      supply = SupplyState.ok;
      _log('supply steady: starts allowed');
      publishSupply();
    }
  }

  // Today's energy, kept like the firmware does: register increases since
  // the first reading of the (local) day.
  var day = _EnergyDay.start(DateTime.now(), meter.kwh);
  void publishEnergyDay(_EnergyDay d) => publish(
      topics.energyDay(d.date),
      PanelTopics.encodeEnergyDay(
          kwh: d.kwh,
          registerKwh: d.registerKwh,
          firstAt: d.firstAt,
          lastAt: d.lastAt,
          gridHourlyKwh: d.gridHourlyKwh,
          generatorKwh: d.generatorKwh,
          generatorSeconds: d.generatorSeconds));

  // Supply source, like the changeover contact on the firmware.
  final generatorHours = _hourRange(options['generator-hours']);
  bool onGeneratorAt(DateTime t) =>
      generatorHours != null &&
      (generatorHours.$1 < generatorHours.$2
          ? t.hour >= generatorHours.$1 && t.hour < generatorHours.$2
          : t.hour >= generatorHours.$1 || t.hour < generatorHours.$2);
  var onGenerator = onGeneratorAt(DateTime.now());
  if (generatorHours != null) {
    publish(
        topics.source, onGenerator ? PanelTopics.generator : PanelTopics.grid);
    _log('on generator from ${generatorHours.$1}:00 to '
        '${generatorHours.$2}:00 (now: ${onGenerator ? 'generator' : 'grid'})');
  }

  final historyDays = int.tryParse(options['history-days'] ?? '') ?? 0;
  if (sensors && historyDays > 0) {
    var register = meter.kwh;
    final today = DateTime.now();
    for (var i = 1; i <= historyDays; i++) {
      final date = DateTime(today.year, today.month, today.day - i);
      final weekend = date.weekday >= DateTime.saturday;
      // A workshop day: mostly 08:00-18:00, some evening work, a base load.
      final hourly = [
        for (var h = 0; h < 24; h++)
          (h >= 8 && h < 18
                  ? (weekend ? 1.5 : 5.0)
                  : (h >= 18 && h < 21 ? 2.0 : 0.6)) *
              (0.8 + random.nextDouble() * 0.4)
      ];
      // Now and then an evening outage, bridged by the generator.
      var generatorKwh = 0.0;
      var generatorSeconds = 0;
      if (generatorHours != null && random.nextDouble() < 0.4) {
        for (final h in [19, 20]) {
          generatorKwh += hourly[h];
          hourly[h] = 0;
        }
        generatorSeconds = 2 * 3600;
      }
      final kwh = hourly.fold(0.0, (a, b) => a + b) + generatorKwh;
      register -= kwh;
      publishEnergyDay(_EnergyDay(
        date: _EnergyDay.dateKey(date),
        kwh: kwh,
        registerKwh: register + kwh,
        firstAt: date.add(const Duration(seconds: 5)),
        lastAt: date.add(const Duration(hours: 23, minutes: 59, seconds: 55)),
        gridHourlyKwh: hourly,
        generatorKwh: generatorKwh,
        generatorSeconds: generatorSeconds,
      ));
    }
    _log('published made-up energy totals for the last $historyDays days');

    // A few past power cuts and a low-voltage spell for the supply log.
    for (final daysAgo in [2, 5, 9, 16]) {
      if (daysAgo > historyDays) continue;
      final from = DateTime(today.year, today.month, today.day - daysAgo,
          9 + random.nextInt(10), random.nextInt(60));
      final low = daysAgo == 5;
      supplyEvents.add(SupplyEvent(
        kind: low ? SupplyState.undervoltage : SupplyState.outage,
        phase: low ? 2 : 1,
        from: from,
        to: from.add(Duration(minutes: 10 + random.nextInt(110))),
        minVolts: low ? 181 : 0,
        maxVolts: low ? 199 : 0,
      ));
    }
    supplyEvents.sort((a, b) => a.from!.compareTo(b.from!));
  }
  if (sensors) {
    publishSupply();
    publishSupplyEvents();
  }
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
    final now = DateTime.now();
    final volts = phaseVolts(now);
    meter.advance(total);
    publish(
        topics.meter,
        PanelTopics.encodeMeter(
            watts: total,
            kwh: meter.kwh,
            volts: [for (final v in volts) v ?? 0]),
        retain: false);
    checkSupply(volts, now);

    final generatorNow = onGeneratorAt(now);
    if (generatorNow != onGenerator) {
      onGenerator = generatorNow;
      publish(topics.source,
          onGenerator ? PanelTopics.generator : PanelTopics.grid);
      _log('supply: ${onGenerator ? 'generator' : 'grid'}');
    }
    if (_EnergyDay.dateKey(now) != day.date) {
      publishEnergyDay(day); // the finished day
      day = _EnergyDay.start(now, meter.kwh);
    } else {
      day = day.advance(now, meter.kwh, onGenerator: onGenerator);
    }
    publishEnergyDay(day);
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

      // Like the firmware: no starts while the supply is bad or settling.
      if (on && !supply.allowsStart) {
        _log('machine $machineId: start refused, supply ${supply.wireName}');
        publish(topics.state(machineId), PanelTopics.off);
        publishEvent(machineId, false, MachineEventCause.refused,
            by: command.by, src: command.src);
        continue;
      }

      if (ignored.contains(machineId)) {
        _log(
            'machine $machineId: ${on ? 'ON' : 'OFF'} received — ignored (simulated fault)');
        continue;
      }
      _log('machine $machineId: switching ${on ? 'ON' : 'OFF'}'
          '${command.by.isEmpty ? '' : ' (by ${command.by})'}…');
      Timer(delay, () {
        final changed = running.contains(machineId) != on;
        on ? running.add(machineId) : running.remove(machineId);
        publish(topics.state(machineId), on ? PanelTopics.on : PanelTopics.off);
        if (changed) {
          publishEvent(machineId, on, MachineEventCause.command,
              by: command.by, src: command.src);
        }
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

/// Parse `kind:start:length` (seconds) for --supply-fault, or null.
({SupplyState kind, Duration start, Duration length})? _parseFault(
    String? value) {
  final parts = (value ?? '').split(':');
  if (parts.length != 3) return null;
  final kind = SupplyStateX.fromWire(parts[0]);
  final start = int.tryParse(parts[1]);
  final length = int.tryParse(parts[2]);
  if (kind == null || !kind.isFault || start == null || length == null) {
    return null;
  }
  return (
    kind: kind,
    start: Duration(seconds: start),
    length: Duration(seconds: length),
  );
}

/// Parse `a-b` (hours 0-24) into a range, or null.
(int, int)? _hourRange(String? value) {
  final parts = (value ?? '').split('-');
  if (parts.length != 2) return null;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  if (a == null || b == null || a < 0 || a > 23 || b < 1 || b > 24 || a == b) {
    return null;
  }
  return (a, b);
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
/// One day's energy total, as the firmware keeps it.
class _EnergyDay {
  _EnergyDay({
    required this.date,
    required this.kwh,
    required this.registerKwh,
    required this.firstAt,
    required this.lastAt,
    required this.gridHourlyKwh,
    this.generatorKwh = 0,
    this.generatorSeconds = 0,
  });

  _EnergyDay.start(DateTime now, double register)
      : this(
            date: dateKey(now),
            kwh: 0,
            registerKwh: register,
            firstAt: now,
            lastAt: now,
            gridHourlyKwh: List.filled(24, 0));

  static String dateKey(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  final String date;
  final double kwh;
  final double registerKwh;
  final DateTime firstAt;
  final DateTime lastAt;
  final List<double> gridHourlyKwh;
  final double generatorKwh;
  final int generatorSeconds;

  _EnergyDay advance(DateTime now, double register,
      {required bool onGenerator}) {
    final added = max(0.0, register - registerKwh);
    final hourly = [...gridHourlyKwh];
    if (!onGenerator) hourly[now.hour] += added;
    return _EnergyDay(
      date: date,
      kwh: kwh + added,
      registerKwh: register,
      firstAt: firstAt,
      lastAt: now,
      gridHourlyKwh: hourly,
      generatorKwh: generatorKwh + (onGenerator ? added : 0),
      generatorSeconds: generatorSeconds +
          (onGenerator ? now.difference(lastAt).inSeconds : 0),
    );
  }
}

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
