// Pure Dart (no Flutter imports) so tool/panel_simulator.dart and any
// future firmware tooling can share the exact same topic contract.

/// MQTT topic contract between the app and a switch panel controller.
///
/// | Topic                                   | Direction   | Payload       | Retained |
/// |-----------------------------------------|-------------|---------------|----------|
/// | `smartautomix/<panel>/machines/<id>/set`   | app → panel | `ON` / `OFF`  | no       |
/// | `smartautomix/<panel>/machines/<id>/state` | panel → app | `ON` / `OFF`  | yes      |
/// | `smartautomix/<panel>/status`              | panel → app | `online` / `offline` (last will) | yes |
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

  /// Subscription filter matching every machine's state topic.
  String get allMachineStates => '$_machines+/state';

  /// Subscription filter matching every machine's command topic.
  String get allMachineCommands => '$_machines+/set';

  String command(String machineId) => '$_machines$machineId/set';
  String state(String machineId) => '$_machines$machineId/state';

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
}
