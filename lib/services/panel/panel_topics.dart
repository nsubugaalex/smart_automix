// Pure Dart (no Flutter imports) so tool/panel_simulator.dart and any
// future firmware tooling can share the exact same topic contract.

import 'dart:convert';

import '../../models/supply.dart';

/// MQTT topic contract between the app and a switch panel controller.
///
/// | Topic                                   | Direction   | Payload       | Retained |
/// |-----------------------------------------|-------------|---------------|----------|
/// | `smartautomix/<panel>/machines/<id>/set`   | app → panel | `{"cmd": "ON", "ts": <ms>}` | no |
/// | `smartautomix/<panel>/machines/<id>/state` | panel → app | `ON` / `OFF`  | yes      |
/// | `smartautomix/<panel>/machines/<id>/hours` | panel → app | `{"s": 720000}` (running seconds) | yes |
/// | `smartautomix/<panel>/machines/<id>/event` | panel → app | `{"on": false, "cause": "trip", "by": "", "src": ""}` | no |
/// | `smartautomix/<panel>/status`              | panel → app | `online` / `offline` (last will) | yes |
/// | `smartautomix/<panel>/machines/<id>/power` | panel → app | `{"w": 7100, "a": 12.4}` | no |
/// | `smartautomix/<panel>/meter`               | panel → app | `{"w": 15200, "kwh": 48211.7}` | no |
/// | `smartautomix/<panel>/energy/<YYYY-MM-DD>` | panel → app | `{"kwh": 79.9, "reg": 48211.7, "first": <s>, "last": <s>, "h": [24 × kWh], "g": 4.2, "gs": 3600}` | yes |
/// | `smartautomix/<panel>/source`              | panel → app | `grid` / `generator` | yes |
/// | `smartautomix/<panel>/supply`              | panel → app | `{"state": "undervoltage", "since": <s>}` | yes |
/// | `smartautomix/<panel>/supply/events`       | panel → app | `[{"kind", "phase", "from", "to", "min", "max"}]` | yes |
class PanelTopics {
  PanelTopics(this.panelId) {
    if (!isValidPanelId(panelId)) {
      throw ArgumentError.value(
          panelId, 'panelId', 'use letters, digits, - or _');
    }
  }

  static const root = 'smartautomix';
  static const on = 'ON';
  static const off = 'OFF';
  static const online = 'online';
  static const offline = 'offline';
  static const grid = 'grid';
  static const generator = 'generator';

  final String panelId;

  /// Panel IDs become a topic level, so they must not contain MQTT
  /// separators or wildcards.
  static bool isValidPanelId(String id) =>
      RegExp(r'^[A-Za-z0-9_-]{3,40}$').hasMatch(id);

  String get _base => '$root/$panelId';
  String get _machines => '$_base/machines/';

  String get status => '$_base/status';

  /// The panel's supply meter: total power and the cumulative kWh register.
  String get meter => '$_base/meter';

  /// Grid or generator supply, from the changeover switch (retained).
  String get source => '$_base/source';

  /// Supply protection state (retained).
  String get supply => '$_base/supply';

  /// The panel's recent supply faults and power cuts (retained).
  String get supplyEvents => '$_base/supply/events';

  String get _energy => '$_base/energy/';

  /// One day's energy total, kept by the panel (retained).
  String energyDay(String date) => '$_energy$date';

  /// Subscription filter matching every day's energy total.
  String get allEnergyDays => '$_energy+';

  /// The `YYYY-MM-DD` date in an energy-day topic, or null.
  String? energyDateFrom(String topic) {
    if (!topic.startsWith(_energy)) return null;
    final date = topic.substring(_energy.length);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) return null;
    // DateTime.parse rolls 2026-13-45 over into a real date; reject that.
    final d = DateTime.parse(date);
    final roundTrip = '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    return roundTrip == date ? date : null;
  }

  /// Subscription filter matching every machine's state topic.
  String get allMachineStates => '$_machines+/state';

  /// Subscription filter matching every machine's command topic.
  String get allMachineCommands => '$_machines+/set';

  /// Subscription filter matching every machine's power reading topic.
  String get allMachinePower => '$_machines+/power';

  String command(String machineId) => '$_machines$machineId/set';
  String state(String machineId) => '$_machines$machineId/state';
  String power(String machineId) => '$_machines$machineId/power';
  String event(String machineId) => '$_machines$machineId/event';
  String hours(String machineId) => '$_machines$machineId/hours';

  /// Subscription filter matching every machine's running-hours topic.
  String get allMachineHours => '$_machines+/hours';

  /// Subscription filter matching every machine's event topic.
  String get allMachineEvents => '$_machines+/event';

  /// The machine ID in a `.../machines/<id>/<suffix>` topic, or null.
  String? machineIdFrom(String topic, {required String suffix}) {
    if (!topic.startsWith(_machines) || !topic.endsWith('/$suffix')) {
      return null;
    }
    final id =
        topic.substring(_machines.length, topic.length - suffix.length - 1);
    return id.isEmpty || id.contains('/') ? null : id;
  }

  /// A command payload: `{"cmd": "ON", "ts": 1792616405123, "by": "Grace",
  /// "src": "3f9a1c2e"}`: the time sent (ms since 1970), the operator and
  /// the app install. The timestamp lets the panel drop an `ON` that
  /// arrives late; `by` and `src` come back in its events.
  static String encodeCommand({
    required bool on,
    required DateTime issuedAt,
    String by = '',
    String src = '',
  }) =>
      jsonEncode({
        'cmd': on ? PanelTopics.on : off,
        'ts': issuedAt.millisecondsSinceEpoch,
        if (by.isNotEmpty) 'by': by,
        if (src.isNotEmpty) 'src': src,
      });

  /// Parse a machine event: `{"on", "cause", "by", "src"}`; null if invalid.
  static ({bool on, MachineEventCause cause, String by, String src})?
      parseMachineEvent(String payload) {
    final json = _decodeObject(payload);
    final on = json?['on'];
    final causeName = json?['cause'];
    if (on is! bool || causeName is! String) return null;
    final cause = MachineEventCause.values
        .where((c) => c.wireName == causeName)
        .firstOrNull;
    if (cause == null) return null;
    String text(Object? v) => v is String ? v : '';
    return (
      on: on,
      cause: cause,
      by: text(json!['by']),
      src: text(json['src'])
    );
  }

  /// Parse a running-hours payload `{"s": <seconds>}`; null if invalid.
  static int? parseHours(String payload) {
    final s = _decodeObject(payload)?['s'];
    return s is int && s >= 0 ? s : null;
  }

  static String encodeHours(int seconds) => jsonEncode({'s': seconds});

  static String encodeMachineEvent({
    required bool on,
    required MachineEventCause cause,
    String by = '',
    String src = '',
  }) =>
      jsonEncode({'on': on, 'cause': cause.wireName, 'by': by, 'src': src});

  /// Parse a command payload: the JSON form from [encodeCommand], or a plain
  /// `ON`/`OFF` (manual testing, older apps). Null if invalid.
  static PanelCommand? parseCommand(String payload) {
    final plain = parseSwitch(payload);
    if (plain != null) return PanelCommand(on: plain);
    final json = _decodeObject(payload);
    final cmd = json?['cmd'];
    final on = cmd is String ? parseSwitch(cmd) : null;
    if (on == null) return null;
    final ts = json!['ts'];
    final by = json['by'];
    final src = json['src'];
    return PanelCommand(
      on: on,
      by: by is String ? by : '',
      src: src is String ? src : '',
      issuedAt: ts is int && ts > 0
          ? DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true)
          : null,
    );
  }

  /// Parse an `ON`/`OFF` payload (case-insensitive); null if invalid.
  static bool? parseSwitch(String payload) {
    switch (payload.trim().toUpperCase()) {
      case on:
        return true;
      case off:
        return false;
    }
    return null;
  }

  /// Parse a machine power payload `{"w": <watts>, "a": <amps>}`; null if
  /// either value is missing, negative or not a number.
  static ({double watts, double amps})? parsePower(String payload) {
    final json = _decodeObject(payload);
    final watts = _nonNegative(json?['w']);
    final amps = _nonNegative(json?['a']);
    if (watts == null || amps == null) return null;
    return (watts: watts, amps: amps);
  }

  /// Parse a meter payload `{"w": <watts>, "kwh": <register>}`; null if
  /// either value is missing, negative or not a number.
  static ({double watts, double kwh})? parseMeter(String payload) {
    final json = _decodeObject(payload);
    final watts = _nonNegative(json?['w']);
    final kwh = _nonNegative(json?['kwh']);
    if (watts == null || kwh == null) return null;
    return (watts: watts, kwh: kwh);
  }

  /// Parse a `supply` payload: `{"state": <name>, "since": <s>}`.
  static ({SupplyState state, DateTime? since})? parseSupply(String payload) {
    final json = _decodeObject(payload);
    final name = json?['state'];
    final state = name is String ? SupplyStateX.fromWire(name) : null;
    if (state == null) return null;
    final since = json!['since'];
    return (
      state: state,
      since: since is int && since > 0
          ? DateTime.fromMillisecondsSinceEpoch(since * 1000)
          : null,
    );
  }

  /// Parse a `supply/events` payload: a JSON list with times in seconds
  /// since 1970 (0 = unknown, or still going on for `to`). Invalid entries
  /// are skipped; null if it isn't a list.
  static List<SupplyEvent>? parseSupplyEvents(String payload) {
    Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      return null;
    }
    if (decoded is! List) return null;
    int? ms(Object? s) => s is int && s > 0 ? s * 1000 : null;
    return [
      for (final e in decoded)
        if (e is Map)
          SupplyEvent.fromJson({
            ...e,
            'from': ms(e['from']),
            'to': ms(e['to']),
          })
    ].nonNulls.toList();
  }

  static String encodeSupply(SupplyState state, {DateTime? since}) =>
      jsonEncode({
        'state': state.wireName,
        'since': since == null ? 0 : since.millisecondsSinceEpoch ~/ 1000,
      });

  static String encodeSupplyEvents(List<SupplyEvent> events) => jsonEncode([
        for (final e in events)
          {
            'kind': e.kind.wireName,
            'phase': e.phase,
            'from': (e.from?.millisecondsSinceEpoch ?? 0) ~/ 1000,
            'to': (e.to?.millisecondsSinceEpoch ?? 0) ~/ 1000,
            'min': _round(e.minVolts, 1),
            'max': _round(e.maxVolts, 1),
          }
      ]);

  /// The phase voltages in a meter payload's optional `v` list; null where
  /// a phase didn't answer, or null if there is no list.
  static List<double?>? parseMeterVolts(String payload) {
    final v = _decodeObject(payload)?['v'];
    if (v is! List) return null;
    return [for (final x in v) _nonNegative(x)];
  }

  /// Parse a `source` payload: true for `generator`, false for `grid`,
  /// null if invalid.
  static bool? parseSource(String payload) {
    switch (payload.trim().toLowerCase()) {
      case generator:
        return true;
      case grid:
        return false;
    }
    return null;
  }

  /// Parse an energy-day payload: `{"kwh", "reg", "first", "last"}` with
  /// the times in seconds since 1970, and optionally `h` (grid kWh for
  /// each of the 24 local hours), `g` (generator kWh) and `gs` (seconds on
  /// generator). Null if invalid, or empty (the panel deleting a day that
  /// dropped out of its history).
  static ({
    double kwh,
    double registerKwh,
    DateTime firstAt,
    DateTime lastAt,
    List<double>? gridHourlyKwh,
    double generatorKwh,
    int generatorSeconds,
  })? parseEnergyDay(String payload) {
    final json = _decodeObject(payload);
    final kwh = _nonNegative(json?['kwh']);
    final reg = _nonNegative(json?['reg']);
    final first = json?['first'];
    final last = json?['last'];
    if (kwh == null || reg == null || first is! int || last is! int) {
      return null;
    }
    if (first <= 0 || last < first) return null;
    final h = json!['h'];
    final hourly = h is List && h.length == 24
        ? [for (final v in h) _nonNegative(v)]
        : null;
    final gs = json['gs'];
    return (
      kwh: kwh,
      registerKwh: reg,
      firstAt: DateTime.fromMillisecondsSinceEpoch(first * 1000),
      lastAt: DateTime.fromMillisecondsSinceEpoch(last * 1000),
      gridHourlyKwh: hourly == null || hourly.contains(null)
          ? null
          : hourly.cast<double>(),
      generatorKwh: _nonNegative(json['g']) ?? 0,
      generatorSeconds: gs is int && gs > 0 ? gs : 0,
    );
  }

  static String encodeEnergyDay({
    required double kwh,
    required double registerKwh,
    required DateTime firstAt,
    required DateTime lastAt,
    List<double>? gridHourlyKwh,
    double generatorKwh = 0,
    int generatorSeconds = 0,
  }) =>
      jsonEncode({
        'kwh': _round(kwh, 3),
        'reg': _round(registerKwh, 3),
        'first': firstAt.millisecondsSinceEpoch ~/ 1000,
        'last': lastAt.millisecondsSinceEpoch ~/ 1000,
        if (gridHourlyKwh != null)
          'h': [for (final v in gridHourlyKwh) _round(v, 3)],
        'g': _round(generatorKwh, 3),
        'gs': generatorSeconds,
      });

  static String encodePower({required double watts, required double amps}) =>
      jsonEncode({'w': _round(watts, 1), 'a': _round(amps, 2)});

  static String encodeMeter(
          {required double watts, required double kwh, List<double>? volts}) =>
      jsonEncode({
        'w': _round(watts, 1),
        'kwh': _round(kwh, 3),
        if (volts != null) 'v': [for (final v in volts) _round(v, 1)],
      });

  static Map<String, dynamic>? _decodeObject(String payload) {
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static double? _nonNegative(Object? value) {
    if (value is! num) return null;
    final d = value.toDouble();
    return d.isFinite && d >= 0 ? d : null;
  }

  static double _round(double value, int decimals) =>
      double.parse(value.toStringAsFixed(decimals));
}

/// An on/off command as received by the panel.
class PanelCommand {
  const PanelCommand(
      {required this.on, this.issuedAt, this.by = '', this.src = ''});

  /// Who sent it (operator name) and from which app install.
  final String by;
  final String src;

  /// How far a command's timestamp may be from the panel's clock. Longer
  /// than the app's 5 s confirm wait, plus room for clocks that differ a
  /// little.
  static const maxAge = Duration(seconds: 10);

  final bool on;

  /// When the app sent it; null for plain `ON`/`OFF` payloads.
  final DateTime? issuedAt;

  /// Whether the panel should drop this command, given its clock reads
  /// [now]. Only a timestamped `ON` that is too old (or too far ahead) is
  /// dropped: by then the app has told the operator the command failed,
  /// so switching on would surprise them. `OFF` is never dropped.
  bool isStaleAt(DateTime now) {
    if (!on || issuedAt == null) return false;
    return now.difference(issuedAt!).abs() > maxAge;
  }
}

/// Why a machine changed, as the panel reports it.
enum MachineEventCause {
  /// A command from an app.
  command,

  /// The contactor dropped out by itself (overload relay, E-stop).
  trip,

  /// Switched at the panel itself.
  panel,

  /// Switched off by supply protection.
  supply,

  /// Told to start, but the contactor didn't close.
  noClose,

  /// A start refused because the supply was bad or settling.
  refused;

  String get wireName => switch (this) {
        MachineEventCause.noClose => 'no_close',
        _ => name,
      };
}
