// Pure Dart (no Flutter imports) so tool/panel_simulator.dart and any
// future firmware tooling can share the exact same topic contract.

import 'dart:convert';

/// MQTT topic contract between the app and a switch panel controller.
///
/// | Topic                                   | Direction   | Payload       | Retained |
/// |-----------------------------------------|-------------|---------------|----------|
/// | `smartautomix/<panel>/machines/<id>/set`   | app → panel | `ON` / `OFF`  | no       |
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
