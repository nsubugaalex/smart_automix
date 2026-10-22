// Pure Dart (no Flutter imports) so tool/panel_simulator.dart and any
// future firmware tooling can share the exact same topic contract.

import 'dart:convert';

/// MQTT topic contract between the app and a switch panel controller.
///
/// | Topic                                   | Direction   | Payload       | Retained |
/// |-----------------------------------------|-------------|---------------|----------|
/// | `smartautomix/<panel>/machines/<id>/set`   | app → panel | `{"cmd": "ON", "ts": <ms>}` | no |
/// | `smartautomix/<panel>/machines/<id>/state` | panel → app | `ON` / `OFF`  | yes      |
/// | `smartautomix/<panel>/status`              | panel → app | `online` / `offline` (last will) | yes |
/// | `smartautomix/<panel>/machines/<id>/power` | panel → app | `{"w": 7100, "a": 12.4}` | no |
/// | `smartautomix/<panel>/meter`               | panel → app | `{"w": 15200, "kwh": 48211.7}` | no |
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

  /// Subscription filter matching every machine's state topic.
  String get allMachineStates => '$_machines+/state';

  /// Subscription filter matching every machine's command topic.
  String get allMachineCommands => '$_machines+/set';

  /// Subscription filter matching every machine's power reading topic.
  String get allMachinePower => '$_machines+/power';

  String command(String machineId) => '$_machines$machineId/set';
  String state(String machineId) => '$_machines$machineId/state';
  String power(String machineId) => '$_machines$machineId/power';

  /// The machine ID in a `.../machines/<id>/<suffix>` topic, or null.
  String? machineIdFrom(String topic, {required String suffix}) {
    if (!topic.startsWith(_machines) || !topic.endsWith('/$suffix')) {
      return null;
    }
    final id =
        topic.substring(_machines.length, topic.length - suffix.length - 1);
    return id.isEmpty || id.contains('/') ? null : id;
  }

  /// A command payload: `{"cmd": "ON", "ts": <ms since 1970>}`. The
  /// timestamp lets the panel drop an `ON` that arrives late.
  static String encodeCommand({required bool on, required DateTime issuedAt}) =>
      jsonEncode({
        'cmd': on ? PanelTopics.on : off,
        'ts': issuedAt.millisecondsSinceEpoch
      });

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
    return PanelCommand(
      on: on,
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

  static String encodePower({required double watts, required double amps}) =>
      jsonEncode({'w': _round(watts, 1), 'a': _round(amps, 2)});

  static String encodeMeter({required double watts, required double kwh}) =>
      jsonEncode({'w': _round(watts, 1), 'kwh': _round(kwh, 3)});

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
  const PanelCommand({required this.on, this.issuedAt});

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
