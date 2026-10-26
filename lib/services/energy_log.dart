import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/energy_prices.dart';

/// One day's energy through the supply meter.
@immutable
class DailyEnergy {
  const DailyEnergy({
    required this.date,
    required this.kwh,
    required this.costUgx,
    required this.lastRegisterKwh,
    required this.firstAt,
    required this.lastAt,
    this.gridHourlyKwh,
    this.generatorKwh = 0,
    this.generatorCostUgx = 0,
    this.generatorSeconds = 0,
  });

  /// Local calendar date, `YYYY-MM-DD`.
  final String date;

  /// All energy through the meter, grid and generator.
  final double kwh;

  /// Grid energy priced at the rate in force when it was used (by the hour
  /// with time-of-use), plus generator energy at fuel cost. Fixed when
  /// recorded, so a later rate change doesn't rewrite past days.
  final double costUgx;

  /// The meter register at [lastAt]; the next reading adds the difference.
  final double lastRegisterKwh;

  /// First and last meter readings of the day. Energy outside this window
  /// wasn't seen, so the day may be incomplete.
  final DateTime firstAt;
  final DateTime lastAt;

  /// Grid energy in each local hour (24 values), or null if not known (an
  /// older panel that only reports day totals).
  final List<double>? gridHourlyKwh;

  /// Energy from the standby generator, its fuel cost, and how long the
  /// panel ran on it.
  final double generatorKwh;
  final double generatorCostUgx;
  final int generatorSeconds;

  double get gridKwh => kwh - generatorKwh;
  double get gridCostUgx => costUgx - generatorCostUgx;

  /// How close to midnight a reading must be for its end of the day to
  /// count as covered.
  static const coverageSlack = Duration(minutes: 15);

  /// Readings further apart than this are a gap (app closed, panel off),
  /// not generator run time.
  static const _maxReadingGap = Duration(minutes: 10);

  DateTime get _midnight => DateTime.parse(date);

  /// Whether readings span the whole day. [now] decides whether the day is
  /// still in progress (today only needs to be covered from midnight).
  bool isCompleteAt(DateTime now) {
    final start = _midnight;
    final end = DateTime(start.year, start.month, start.day + 1);
    final coversStart = firstAt.difference(start) <= coverageSlack;
    final coversEnd =
        now.isBefore(end) || end.difference(lastAt) <= coverageSlack;
    return coversStart && coversEnd;
  }

  DailyEnergy _add(
    double register,
    DateTime at, {
    required bool onGenerator,
    required EnergyPrices prices,
  }) {
    final delta = register - lastRegisterKwh;
    // A register that went backwards was replaced or reset: carry on
    // counting from its new value without adding anything.
    final added = delta > 0 ? delta : 0.0;
    if (onGenerator) {
      final gap = at.difference(lastAt);
      final cost = added * prices.generatorRatePerKwh;
      return _copy(
        kwh: kwh + added,
        costUgx: costUgx + cost,
        register: register,
        at: at,
        generatorKwh: generatorKwh + added,
        generatorCostUgx: generatorCostUgx + cost,
        generatorSeconds: generatorSeconds +
            (gap <= _maxReadingGap && !gap.isNegative ? gap.inSeconds : 0),
      );
    }
    final hourly = gridHourlyKwh == null ? null : [...gridHourlyKwh!];
    if (hourly != null) hourly[at.hour] += added;
    return _copy(
      kwh: kwh + added,
      costUgx: costUgx + added * prices.gridRateAt(at),
      register: register,
      at: at,
      gridHourlyKwh: hourly,
    );
  }

  DailyEnergy _copy({
    required double kwh,
    required double costUgx,
    required double register,
    required DateTime at,
    List<double>? gridHourlyKwh,
    double? generatorKwh,
    double? generatorCostUgx,
    int? generatorSeconds,
  }) =>
      DailyEnergy(
        date: date,
        kwh: kwh,
        costUgx: costUgx,
        lastRegisterKwh: register,
        firstAt: firstAt,
        lastAt: at,
        gridHourlyKwh: gridHourlyKwh ?? this.gridHourlyKwh,
        generatorKwh: generatorKwh ?? this.generatorKwh,
        generatorCostUgx: generatorCostUgx ?? this.generatorCostUgx,
        generatorSeconds: generatorSeconds ?? this.generatorSeconds,
      );

  Map<String, Object> toJson() => {
        'date': date,
        'kwh': kwh,
        'cost': costUgx,
        'reg': lastRegisterKwh,
        'first': firstAt.toIso8601String(),
        'last': lastAt.toIso8601String(),
        if (gridHourlyKwh != null) 'h': gridHourlyKwh!,
        if (generatorKwh > 0) 'g': generatorKwh,
        if (generatorCostUgx > 0) 'gc': generatorCostUgx,
        if (generatorSeconds > 0) 'gs': generatorSeconds,
      };

  static DailyEnergy? fromJson(Object? json) {
    if (json is! Map) return null;
    final date = json['date'];
    final kwh = json['kwh'];
    final cost = json['cost'];
    final reg = json['reg'];
    final first = DateTime.tryParse('${json['first']}');
    final last = DateTime.tryParse('${json['last']}');
    if (date is! String ||
        DateTime.tryParse(date) == null ||
        kwh is! num ||
        cost is! num ||
        reg is! num ||
        first == null ||
        last == null) {
      return null;
    }
    final hourly = json['h'];
    double number(Object? v) => v is num ? v.toDouble() : 0;
    return DailyEnergy(
      date: date,
      kwh: kwh.toDouble(),
      costUgx: cost.toDouble(),
      lastRegisterKwh: reg.toDouble(),
      firstAt: first,
      lastAt: last,
      gridHourlyKwh: hourly is List && hourly.length == 24
          ? [for (final v in hourly) number(v)]
          : null,
      generatorKwh: number(json['g']),
      generatorCostUgx: number(json['gc']),
      generatorSeconds: json['gs'] is int ? json['gs'] as int : 0,
    );
  }
}

/// Day-by-day energy and cost from the supply meter's kWh register.
///
/// Each reading adds the increase since the previous one to its day (and
/// hour, or to the generator), so a day's total stays right across app
/// restarts (the register keeps counting while the app is closed) and
/// across a meter reset. Energy used between the last reading of one day
/// and the first of the next isn't assigned to either, which is why days
/// carry their coverage.
class EnergyLog {
  EnergyLog([Iterable<DailyEnergy> days = const []]) {
    for (final day in days) {
      _days[day.date] = day;
    }
    _prune();
  }

  /// About 13 months, enough to compare with the same month last year.
  static const maxDays = 400;

  // Sorted by date: `YYYY-MM-DD` strings sort chronologically.
  final _days = SplayTreeMap<String, DailyEnergy>();

  static String dateKey(DateTime t) => '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  /// All recorded days, oldest first.
  Iterable<DailyEnergy> get days => _days.values;

  bool get isEmpty => _days.isEmpty;

  DailyEnergy? day(DateTime date) => _days[dateKey(date)];

  /// The [count] days ending with [today], oldest first; null where there
  /// is no record.
  List<DailyEnergy?> lastDays(int count, DateTime today) {
    final end = DateTime(today.year, today.month, today.day);
    return [
      for (var i = count - 1; i >= 0; i--)
        _days[dateKey(DateTime(end.year, end.month, end.day - i))],
    ];
  }

  /// Add a meter reading taken at [at], while the supply was the generator
  /// if [onGenerator]. Returns true when it started a new day, which is
  /// worth saving straight away.
  bool record({
    required double registerKwh,
    required DateTime at,
    required EnergyPrices prices,
    bool onGenerator = false,
  }) {
    final key = dateKey(at);
    final existing = _days[key];
    if (existing != null) {
      _days[key] = existing._add(registerKwh, at,
          onGenerator: onGenerator, prices: prices);
      return false;
    }
    _days[key] = DailyEnergy(
      date: key,
      kwh: 0,
      costUgx: 0,
      lastRegisterKwh: registerKwh,
      firstAt: at,
      lastAt: at,
      gridHourlyKwh: List.filled(24, 0),
    );
    _prune();
    return true;
  }

  /// Take a day's total from the panel, which is always on and so usually
  /// saw more of the day than the app. Returns whether it changed the log.
  ///
  /// The panel's figure replaces the app's own unless the app counted more
  /// (e.g. a new controller that started partway through the day), and a
  /// day the log already has in the same state (retained messages arrive
  /// again on every connect) is left alone. Its register value becomes the
  /// base for the app's next live reading, so nothing is counted twice.
  ///
  /// With [gridHourlyKwh], grid energy is priced hour by hour at [prices].
  /// Without it, the cost keeps the average rate the app had priced that
  /// day at, or the day's average rate for a day the app never saw.
  bool applyPanelDay({
    required String date,
    required double kwh,
    required double registerKwh,
    required DateTime firstAt,
    required DateTime lastAt,
    required EnergyPrices prices,
    List<double>? gridHourlyKwh,
    double generatorKwh = 0,
    int generatorSeconds = 0,
  }) {
    final existing = _days[date];
    if (existing != null &&
        (existing.kwh > kwh ||
            (existing.kwh == kwh && !lastAt.isAfter(existing.lastAt)))) {
      return false;
    }
    final midnight = DateTime.parse(date);
    final hourly = gridHourlyKwh != null && gridHourlyKwh.length == 24
        ? gridHourlyKwh
        : null;

    final double gridCost;
    if (hourly != null) {
      var sum = 0.0;
      for (var h = 0; h < 24; h++) {
        sum += hourly[h] *
            prices.gridRateAt(
                DateTime(midnight.year, midnight.month, midnight.day, h));
      }
      gridCost = sum;
    } else {
      final gridKwh = kwh - generatorKwh;
      final rate = existing != null && existing.gridKwh > 0
          ? existing.gridCostUgx / existing.gridKwh
          : _averageRate(midnight, prices);
      gridCost = gridKwh * rate;
    }
    final generatorRate = existing != null && existing.generatorKwh > 0
        ? existing.generatorCostUgx / existing.generatorKwh
        : prices.generatorRatePerKwh;
    final generatorCost = generatorKwh * generatorRate;

    _days[date] = DailyEnergy(
      date: date,
      kwh: kwh,
      costUgx: gridCost + generatorCost,
      lastRegisterKwh: registerKwh,
      firstAt: firstAt,
      lastAt: lastAt,
      gridHourlyKwh: hourly == null ? null : List.of(hourly),
      generatorKwh: generatorKwh,
      generatorCostUgx: generatorCost,
      generatorSeconds: generatorSeconds,
    );
    _prune();
    return true;
  }

  static double _averageRate(DateTime midnight, EnergyPrices prices) {
    var sum = 0.0;
    for (var h = 0; h < 24; h++) {
      sum += prices
          .gridRateAt(DateTime(midnight.year, midnight.month, midnight.day, h));
    }
    return sum / 24;
  }

  /// Start [date]'s record from a known register value without a reading
  /// (used to carry over the older single-day format).
  void seedDay(DateTime date, {required double registerKwh}) {
    _days.putIfAbsent(
      dateKey(date),
      () => DailyEnergy(
        date: dateKey(date),
        kwh: 0,
        costUgx: 0,
        lastRegisterKwh: registerKwh,
        firstAt: date,
        lastAt: date,
      ),
    );
  }

  void _prune() {
    while (_days.length > maxDays) {
      _days.remove(_days.firstKey());
    }
  }

  String toJson() => jsonEncode([for (final d in _days.values) d.toJson()]);

  static EnergyLog fromJson(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return EnergyLog();
      return EnergyLog(decoded.map(DailyEnergy.fromJson).nonNulls);
    } on FormatException {
      return EnergyLog();
    }
  }

  /// The history as CSV, oldest day first, for a spreadsheet or to check
  /// against the UEDCL bill.
  String toCsv({required DateTime now}) {
    final rows = [
      'date,kwh,cost_ugx,generator_kwh,generator_cost_ugx,generator_hours,'
          'first_reading,last_reading,complete',
      for (final d in _days.values)
        [
          d.date,
          d.kwh.toStringAsFixed(2),
          d.costUgx.toStringAsFixed(0),
          d.generatorKwh.toStringAsFixed(2),
          d.generatorCostUgx.toStringAsFixed(0),
          (d.generatorSeconds / 3600).toStringAsFixed(2),
          _time(d.firstAt),
          _time(d.lastAt),
          d.isCompleteAt(now) ? 'yes' : 'no',
        ].join(','),
    ];
    return '${rows.join('\n')}\n';
  }

  static String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
