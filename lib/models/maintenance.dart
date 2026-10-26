import 'package:flutter/foundation.dart';

enum TaskStatus { ok, soon, due }

/// A recurring maintenance job for one machine (or the standby generator),
/// due after a number of running hours, a number of days, or whichever
/// comes first.
@immutable
class MaintenanceTask {
  const MaintenanceTask({
    required this.id,
    required this.machineId,
    required this.title,
    this.everyHours,
    this.everyDays,
    required this.doneAtHours,
    required this.doneOn,
  });

  /// The machine ID used for the standby generator's tasks.
  static const generatorId = '__generator__';

  /// "Due soon" from this share of the interval.
  static const soonAt = 0.9;

  final String id;
  final String machineId;
  final String title;
  final int? everyHours;
  final int? everyDays;

  /// The machine's running hours and the date when it was last done (or
  /// the task was added).
  final double doneAtHours;
  final DateTime doneOn;

  /// How far through its interval the task is (1 = due), the larger of the
  /// hours and days measures.
  double progress(double hoursNow, DateTime now) {
    var p = 0.0;
    if (everyHours != null && everyHours! > 0) {
      p = (hoursNow - doneAtHours) / everyHours!;
    }
    if (everyDays != null && everyDays! > 0) {
      final days = now.difference(doneOn).inMinutes / (24 * 60);
      final d = days / everyDays!;
      if (d > p) p = d;
    }
    return p < 0 ? 0 : p;
  }

  TaskStatus statusAt(double hoursNow, DateTime now) {
    final p = progress(hoursNow, now);
    if (p >= 1) return TaskStatus.due;
    if (p >= soonAt) return TaskStatus.soon;
    return TaskStatus.ok;
  }

  /// "every 200 h", "every 30 days" or "every 250 h or 90 days".
  String get intervalText {
    final parts = [
      if (everyHours != null) '${everyHours!} h',
      if (everyDays != null) '${everyDays!} day${everyDays == 1 ? '' : 's'}',
    ];
    return 'every ${parts.join(' or ')}';
  }

  /// "due in 42 h", "due in 5 days" or "overdue by 12 h": the sooner of
  /// the two measures.
  String dueText(double hoursNow, DateTime now) {
    final parts = <(double, String)>[];
    if (everyHours != null) {
      final left = doneAtHours + everyHours! - hoursNow;
      parts.add((left / everyHours!, _amount(left, 'h')));
    }
    if (everyDays != null) {
      final left = everyDays! - now.difference(doneOn).inHours / 24;
      parts.add((left / everyDays!, _amount(left, 'days')));
    }
    if (parts.isEmpty) return '';
    parts.sort((a, b) => a.$1.compareTo(b.$1));
    return parts.first.$2;
  }

  static String _amount(double left, String unit) {
    final n = left.abs().round();
    final u = unit == 'days' && n == 1 ? 'day' : unit;
    final spaced = u == 'h' ? '$n h' : '$n $u';
    return left < 0 ? 'overdue by $spaced' : 'due in $spaced';
  }

  MaintenanceTask copyWith({
    String? title,
    int? Function()? everyHours,
    int? Function()? everyDays,
    double? doneAtHours,
    DateTime? doneOn,
  }) =>
      MaintenanceTask(
        id: id,
        machineId: machineId,
        title: title ?? this.title,
        everyHours: everyHours != null ? everyHours() : this.everyHours,
        everyDays: everyDays != null ? everyDays() : this.everyDays,
        doneAtHours: doneAtHours ?? this.doneAtHours,
        doneOn: doneOn ?? this.doneOn,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'machine': machineId,
        'title': title,
        'hours': everyHours,
        'days': everyDays,
        'doneAt': doneAtHours,
        'doneOn': doneOn.millisecondsSinceEpoch,
      };

  static MaintenanceTask? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], machine = json['machine'], title = json['title'];
    final doneAt = json['doneAt'], doneOn = json['doneOn'];
    if (id is! String ||
        machine is! String ||
        title is! String ||
        doneAt is! num ||
        doneOn is! int) {
      return null;
    }
    return MaintenanceTask(
      id: id,
      machineId: machine,
      title: title,
      everyHours: json['hours'] is int ? json['hours'] as int : null,
      everyDays: json['days'] is int ? json['days'] as int : null,
      doneAtHours: doneAt.toDouble(),
      doneOn: DateTime.fromMillisecondsSinceEpoch(doneOn),
    );
  }

  /// Typical jobs for a machine type, as starting points. They are not the
  /// manufacturer's schedule: check the machine's manual and adjust.
  static List<({String title, int? hours, int? days})> suggestionsFor(
      String type) {
    return switch (type) {
      'mill' => const [
          (title: 'Grease the bearings', hours: 200, days: null),
          (title: 'Check and tension the belts', hours: 100, days: null),
          (title: 'Check hammers or plates for wear', hours: 300, days: null),
        ],
      'grinder' => const [
          (title: 'Check and tension the belts', hours: 100, days: null),
          (title: 'Grease the bearings', hours: 300, days: null),
        ],
      'compressor' => const [
          (title: 'Drain water from the tank', hours: null, days: 7),
          (title: 'Clean the air filter', hours: 250, days: null),
          (title: 'Change the oil', hours: 500, days: 180),
        ],
      'welder' => const [
          (title: 'Check cables, clamps and earth', hours: null, days: 30),
          (title: 'Blow out dust from the inside', hours: 250, days: null),
        ],
      'pump' => const [
          (title: 'Check the seal for leaks', hours: null, days: 30),
          (title: 'Grease the motor bearings', hours: 1000, days: null),
        ],
      'coldroom' => const [
          (title: 'Clean the condenser coils', hours: null, days: 30),
        ],
      'lathe' => const [
          (
            title: 'Lubricate the ways and check the oil',
            hours: 50,
            days: null
          ),
        ],
      MaintenanceTask.generatorId => const [
          (title: 'Change the oil and oil filter', hours: 250, days: 180),
          (title: 'Check oil, coolant and battery', hours: null, days: 7),
          (title: 'Clean or replace the air filter', hours: 250, days: null),
        ],
      'motor' || 'oven' || 'other' => const [
          (
            title: 'Check the motor bearings and clean the vents',
            hours: 500,
            days: null
          ),
        ],
      _ => const [],
    };
  }
}
