// Pure Dart (no Flutter imports): shared with tool/panel_simulator.dart
// through the topic contract.

/// The supply as the panel judges it (from the incomer meter's voltages).
enum SupplyState {
  ok,

  /// Back in range after a fault, waiting to be steady before the panel
  /// allows starts.
  settling,
  undervoltage,
  overvoltage,
  phaseLoss,

  /// Every phase dead (a power cut).
  outage,
}

extension SupplyStateX on SupplyState {
  /// The name used in MQTT payloads.
  String get wireName => switch (this) {
        SupplyState.ok => 'ok',
        SupplyState.settling => 'settling',
        SupplyState.undervoltage => 'undervoltage',
        SupplyState.overvoltage => 'overvoltage',
        SupplyState.phaseLoss => 'phase_loss',
        SupplyState.outage => 'outage',
      };

  static SupplyState? fromWire(String name) {
    for (final s in SupplyState.values) {
      if (s.wireName == name.trim().toLowerCase()) return s;
    }
    return null;
  }

  String get label => switch (this) {
        SupplyState.ok => 'Supply normal',
        SupplyState.settling => 'Supply settling',
        SupplyState.undervoltage => 'Low voltage',
        SupplyState.overvoltage => 'High voltage',
        SupplyState.phaseLoss => 'Phase lost',
        SupplyState.outage => 'Power cut',
      };

  bool get isFault => this != SupplyState.ok && this != SupplyState.settling;

  /// Whether the panel accepts machine starts.
  bool get allowsStart => this == SupplyState.ok;
}

/// "1 h 5 min", "35 min" or "40 s".
String formatDuration(Duration d) {
  if (d.inMinutes < 1) return '${d.inSeconds} s';
  if (d.inHours < 1) return '${d.inMinutes} min';
  final minutes = d.inMinutes % 60;
  return minutes == 0 ? '${d.inHours} h' : '${d.inHours} h $minutes min';
}

/// One supply fault or power cut, from the panel's log.
class SupplyEvent {
  const SupplyEvent({
    required this.kind,
    required this.phase,
    required this.from,
    required this.to,
    required this.minVolts,
    required this.maxVolts,
  });

  final SupplyState kind;

  /// Phase number (1-3) the fault was seen on.
  final int phase;

  /// When it started and ended; null if the panel's clock wasn't set, or
  /// ([to]) while it's still going on. A power cut that switched the
  /// controller off starts within a few minutes of [from].
  final DateTime? from;
  final DateTime? to;
  final double minVolts;
  final double maxVolts;

  bool get isOngoing => to == null;

  /// What happened, e.g. "Low voltage on phase 2 (lowest 183 V)".
  String get summary => switch (kind) {
        SupplyState.undervoltage =>
          'Low voltage on phase $phase (lowest ${minVolts.round()} V)',
        SupplyState.overvoltage =>
          'High voltage on phase $phase (highest ${maxVolts.round()} V)',
        SupplyState.phaseLoss => 'Phase $phase lost',
        _ => 'Power cut',
      };

  Duration? get duration =>
      from != null && to != null ? to!.difference(from!) : null;

  /// Identifies the event across repeated deliveries.
  String get key => '${kind.wireName}@${from?.millisecondsSinceEpoch ?? 0}'
      '#$phase';

  Map<String, Object?> toJson() => {
        'kind': kind.wireName,
        'phase': phase,
        'from': from?.millisecondsSinceEpoch,
        'to': to?.millisecondsSinceEpoch,
        'min': minVolts,
        'max': maxVolts,
      };

  static SupplyEvent? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = json['kind'];
    final state = kind is String ? SupplyStateX.fromWire(kind) : null;
    if (state == null || !state.isFault) return null;
    DateTime? time(Object? ms) =>
        ms is int && ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
    double number(Object? v) => v is num ? v.toDouble() : 0;
    return SupplyEvent(
      kind: state,
      phase: json['phase'] is int ? json['phase'] as int : 1,
      from: time(json['from']),
      to: time(json['to']),
      minVolts: number(json['min']),
      maxVolts: number(json['max']),
    );
  }
}
