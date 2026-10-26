import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_automix/models/machine_health.dart';

void main() {
  final today = DateTime(2026, 10, 26, 10);
  String day(int daysAgo) {
    final t = today.subtract(Duration(days: daysAgo));
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')}';
  }

  /// A day of [n] running samples around [mean] A, spread by [noise].
  DayCurrent sampled(int daysAgo, double mean,
      {double noise = 0.4, int n = 500, int seed = 1}) {
    final r = Random(seed + daysAgo);
    final d = DayCurrent(day(daysAgo));
    for (var i = 0; i < n; i++) {
      d.add(mean + (r.nextDouble() * 2 - 1) * noise);
    }
    return d;
  }

  /// [baseline] normal days (around 12 A, wandering a little) followed by
  /// the given recent days, oldest first.
  List<DayCurrent> history(List<DayCurrent> recent, {int baseline = 10}) => [
        for (var i = baseline + recent.length; i > recent.length; i--)
          sampled(i, 12 + sin(i.toDouble()) * 0.3),
        ...recent,
      ];

  MachineHealthStatus analyze(List<DayCurrent> days, {String? learnFrom}) =>
      MachineHealthAnalysis.analyze(days, today: today, learnFrom: learnFrom);

  test('learns for 5 running days before judging', () {
    final s = analyze([for (var i = 4; i >= 1; i--) sampled(i, 12)]);
    expect(s.isLearning, isTrue);
    expect(s.learnedDays, 4);
  });

  test('short runs and today do not count towards learning', () {
    final s = analyze([
      for (var i = 6; i >= 1; i--) sampled(i, 12, n: 100), // under 20 min
      sampled(0, 12), // today
    ]);
    expect(s.learnedDays, 0);
  });

  test('normal running: no finding, and the usual range', () {
    final s = analyze(
        history([sampled(3, 12.1), sampled(2, 11.9), sampled(1, 12.2)]));
    expect(s.isLearning, isFalse);
    expect(s.finding, isNull);
    expect(s.usual, closeTo(12, 0.3));
    expect(s.usualLow, lessThan(s.usual!));
    expect(s.usualHigh, greaterThan(s.usual!));
  });

  test('three days of 25% more current is reported as high', () {
    final s =
        analyze(history([sampled(3, 15), sampled(2, 15.2), sampled(1, 14.9)]));
    expect(s.finding, HealthKind.high);
    expect(s.percent, closeTo(25, 3));
    expect(s.days, 3);
  });

  test('a single bad day is not enough', () {
    final s =
        analyze(history([sampled(3, 12), sampled(2, 16), sampled(1, 12.1)]));
    expect(s.finding, isNull);
  });

  test('less current than usual is reported as low', () {
    final s =
        analyze(history([sampled(3, 9.5), sampled(2, 9.6), sampled(1, 9.4)]));
    expect(s.finding, HealthKind.low);
    expect(s.percent, lessThan(-15));
  });

  test('a small change within the threshold is not flagged', () {
    final s =
        analyze(history([sampled(3, 13), sampled(2, 13.1), sampled(1, 12.9)]));
    expect(s.finding, isNull, reason: 'about 8% more: under the 15% threshold');
  });

  test('much bigger swings within the day are reported as erratic', () {
    final s = analyze(history([
      sampled(3, 12, noise: 4),
      sampled(2, 12, noise: 4.2),
      sampled(1, 12.1, noise: 3.9),
    ]));
    expect(s.finding, HealthKind.erratic);
  });

  test('relearning ignores the days before it', () {
    final days = history([sampled(3, 15), sampled(2, 15.2), sampled(1, 14.9)]);
    final s = analyze(days, learnFrom: day(3));
    expect(s.isLearning, isTrue);
    expect(s.learnedDays, 3);
  });

  test('daily stats survive a JSON round trip', () {
    final d = sampled(1, 12);
    final copy = DayCurrent.fromJson(d.toJson())!;
    expect(copy.mean, d.mean);
    expect(copy.std, closeTo(d.std, 1e-12));
    expect(copy.peak, d.peak);
  });

  test('causes are worded for the machine type', () {
    expect(MachineHealthAnalysis.causes(HealthKind.high, 'mill'),
        contains('hammers'));
    expect(MachineHealthAnalysis.causes(HealthKind.low, 'pump'),
        contains('dry suction'));
  });
}
