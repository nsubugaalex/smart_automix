import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// One day's running current for a machine: count, mean and spread
/// (Welford's method, so it can be updated sample by sample) and peak.
class DayCurrent {
  DayCurrent(this.date,
      {this.n = 0, this.mean = 0, this.m2 = 0, this.peak = 0});

  /// Local date, `YYYY-MM-DD`.
  final String date;
  int n;
  double mean;
  double m2;
  double peak;

  void add(double amps) {
    n++;
    final delta = amps - mean;
    mean += delta / n;
    m2 += delta * (amps - mean);
    if (amps > peak) peak = amps;
  }

  double get std => n > 1 ? math.sqrt(m2 / (n - 1)) : 0;

  Map<String, Object> toJson() =>
      {'d': date, 'n': n, 'mean': mean, 'm2': m2, 'peak': peak};

  static DayCurrent? fromJson(Object? json) {
    if (json is! Map || json['d'] is! String || json['n'] is! int) return null;
    double number(Object? v) => v is num ? v.toDouble() : 0;
    return DayCurrent(json['d'] as String,
        n: json['n'] as int,
        mean: number(json['mean']),
        m2: number(json['m2']),
        peak: number(json['peak']));
  }
}

enum HealthKind {
  /// Drawing more current than usual.
  high,

  /// Drawing less current than usual.
  low,

  /// Current swinging much more than usual within a day.
  erratic,
}

/// What the analysis found for one machine.
@immutable
class MachineHealthStatus {
  const MachineHealthStatus({
    required this.learnedDays,
    this.usual,
    this.usualLow,
    this.usualHigh,
    this.recent,
    this.finding,
    this.percent,
    this.days = 0,
  });

  /// Days with enough running so far (the baseline needs
  /// [MachineHealthAnalysis.daysToLearn]).
  final int learnedDays;

  /// The usual running current and its normal day-to-day range, once
  /// learned.
  final double? usual;
  final double? usualLow;
  final double? usualHigh;

  /// The average over the recent days compared.
  final double? recent;

  /// What's unusual, if anything, by how much (percent, signed), and over
  /// how many days.
  final HealthKind? finding;
  final double? percent;
  final int days;

  bool get isLearning => usual == null;
}

/// Compares a machine's recent running current with what's normal for it.
///
/// "Normal" is the median of its daily average current over the past
/// month (not counting the most recent days), with a robust spread (the
/// median absolute deviation), so one odd day can't skew it. A finding
/// needs every one of the last [recentDays] running days to be out of
/// line, by at least [changeThreshold] and clearly outside the normal
/// day-to-day variation.
class MachineHealthAnalysis {
  const MachineHealthAnalysis._();

  /// Running samples a day needs to count (at one sample every 5 s, about
  /// 20 minutes of running).
  static const minSamplesPerDay = 240;

  /// Days of running needed before judging anything.
  static const daysToLearn = 5;

  /// Recent running days compared with the baseline.
  static const recentDays = 3;

  /// How far back the baseline looks.
  static const baselineWindow = Duration(days: 35);

  /// Smallest change worth reporting (15%).
  static const changeThreshold = 0.15;

  /// Within-day swings this many times the usual count as erratic.
  static const erraticFactor = 1.8;

  static double _median(List<double> xs) {
    final s = [...xs]..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }

  /// [days] oldest first. Only days on or after [learnFrom] count (after a
  /// "relearn"). [today] is excluded as it's still running.
  static MachineHealthStatus analyze(List<DayCurrent> days,
      {required DateTime today, String? learnFrom}) {
    final todayKey = _key(today);
    final oldest = _key(today.subtract(baselineWindow));
    final usable = days
        .where((d) =>
            d.n >= minSamplesPerDay &&
            d.date.compareTo(todayKey) < 0 &&
            d.date.compareTo(oldest) >= 0 &&
            (learnFrom == null || d.date.compareTo(learnFrom) >= 0))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    if (usable.length < daysToLearn) {
      return MachineHealthStatus(learnedDays: usable.length);
    }
    // Compare the last few days only once there's a baseline without them.
    final recent = usable.length >= daysToLearn + recentDays
        ? usable.sublist(usable.length - recentDays)
        : <DayCurrent>[];
    final base = usable.sublist(0, usable.length - recent.length);

    final means = [for (final d in base) d.mean];
    final usual = _median(means);
    final mad = _median([for (final m in means) (m - usual).abs()]);
    // A robust standard deviation, with a floor of 3% of the usual current
    // so a very steady machine isn't flagged for tiny changes.
    final spread = math.max(1.4826 * mad, 0.03 * usual);
    final usualLow = usual - 2 * spread;
    final usualHigh = usual + 2 * spread;

    if (recent.isEmpty || usual <= 0) {
      return MachineHealthStatus(
          learnedDays: usable.length,
          usual: usual,
          usualLow: usualLow,
          usualHigh: usualHigh);
    }

    final recentMean = recent.fold(0.0, (s, d) => s + d.mean) / recent.length;
    bool allAbove(double limit) => recent.every((d) => d.mean > limit);
    bool allBelow(double limit) => recent.every((d) => d.mean < limit);

    HealthKind? finding;
    if (allAbove(math.max(usual * (1 + changeThreshold), usualHigh))) {
      finding = HealthKind.high;
    } else if (allBelow(math.min(usual * (1 - changeThreshold), usualLow))) {
      finding = HealthKind.low;
    } else {
      final usualStd = _median([for (final d in base) d.std]);
      if (usualStd > 0 &&
          recent.every((d) =>
              d.std > usualStd * erraticFactor && d.std > 0.1 * d.mean)) {
        finding = HealthKind.erratic;
      }
    }
    return MachineHealthStatus(
      learnedDays: usable.length,
      usual: usual,
      usualLow: usualLow,
      usualHigh: usualHigh,
      recent: recentMean,
      finding: finding,
      percent: (recentMean / usual - 1) * 100,
      days: finding == null ? 0 : recent.length,
    );
  }

  static String _key(DateTime t) => '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  /// Likely causes, worth checking, for a finding on a machine of [type].
  static String causes(HealthKind kind, String type) => switch (kind) {
        HealthKind.high => switch (type) {
            'mill' ||
            'grinder' =>
              'worn bearings, blunt hammers or plates, a jam, or low voltage',
            'compressor' => 'a leak, worn valves, or a dirty air filter',
            'pump' => 'a blockage, a worn impeller, or bearings',
            _ => 'worn bearings, a jam, extra load, or low voltage',
          },
        HealthKind.low => switch (type) {
            'mill' ||
            'grinder' ||
            'lathe' =>
              'a slipping belt, or the machine running lightly loaded',
            'pump' => 'a dry suction or air in the pump',
            _ => 'a slipping belt, or a lighter load than usual',
          },
        HealthKind.erratic =>
          'an intermittent jam, a loose connection, or a worn part',
      };
}
