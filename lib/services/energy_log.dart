import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

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
  });

  /// Local calendar date, `YYYY-MM-DD`.
  final String date;
  final double kwh;

  /// Each increase priced at the tariff rate in force when it was read, so
  /// a later rate change doesn't rewrite past days.
  final double costUgx;

  /// The meter register at [lastAt]; the next reading adds the difference.
  final double lastRegisterKwh;

  /// First and last meter readings of the day. Energy outside this window
  /// wasn't seen (the app was closed), so the day may be incomplete.
  final DateTime firstAt;
  final DateTime lastAt;

  /// How close to midnight a reading must be for its end of the day to
  /// count as covered.
  static const coverageSlack = Duration(minutes: 15);

  /// Whether readings span the whole day. [now] decides whether the day is
  /// still in progress (today only needs to be covered from midnight).
  bool isCompleteAt(DateTime now) {
    final start = DateTime.parse(date);
    final end = start.add(const Duration(days: 1));
    final coversStart = firstAt.difference(start) <= coverageSlack;
    final coversEnd =
        now.isBefore(end) || end.difference(lastAt) <= coverageSlack;
    return coversStart && coversEnd;
  }

  DailyEnergy _add(double register, DateTime at, double ratePerKwh) {
    final delta = register - lastRegisterKwh;
    // A register that went backwards was replaced or reset: carry on
    // counting from its new value without adding anything.
    final added = delta > 0 ? delta : 0.0;
    return DailyEnergy(
      date: date,
      kwh: kwh + added,
      costUgx: costUgx + added * ratePerKwh,
      lastRegisterKwh: register,
      firstAt: firstAt,
      lastAt: at,
    );
  }

  Map<String, Object> toJson() => {
        'date': date,
        'kwh': kwh,
        'cost': costUgx,
        'reg': lastRegisterKwh,
        'first': firstAt.toIso8601String(),
        'last': lastAt.toIso8601String(),
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
    return DailyEnergy(
      date: date,
      kwh: kwh.toDouble(),
      costUgx: cost.toDouble(),
      lastRegisterKwh: reg.toDouble(),
      firstAt: first,
      lastAt: last,
    );
  }
}

/// Day-by-day energy and cost from the supply meter's kWh register.
///
/// Each reading adds the increase since the previous one to its day, so a
/// day's total stays right across app restarts (the register keeps
/// counting while the app is closed) and across a meter reset. Energy used
/// between the last reading of one day and the first of the next isn't
/// assigned to either, which is why days carry their coverage.
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

  /// Add a meter reading. Returns true when it started a new day, which is
  /// worth saving straight away.
  bool record({
    required double registerKwh,
    required DateTime at,
    required double ratePerKwh,
  }) {
    final key = dateKey(at);
    final existing = _days[key];
    if (existing != null) {
      _days[key] = existing._add(registerKwh, at, ratePerKwh);
      return false;
    }
    _days[key] = DailyEnergy(
      date: key,
      kwh: 0,
      costUgx: 0,
      lastRegisterKwh: registerKwh,
      firstAt: at,
      lastAt: at,
    );
    _prune();
    return true;
  }

  /// Take a day's total from the panel, which is always on and so usually
  /// saw more of the day than the app. Returns whether it changed the log.
  ///
  /// The panel's figure replaces the app's own unless the app counted more
  /// (e.g. a new controller that started partway through the day). Its
  /// register value becomes the base for the app's next live reading, so
  /// nothing is counted twice. The cost keeps the rate the app had priced
  /// that day at; a day the app never saw is priced at [ratePerKwh].
  bool applyPanelDay({
    required String date,
    required double kwh,
    required double registerKwh,
    required DateTime firstAt,
    required DateTime lastAt,
    required double ratePerKwh,
  }) {
    final existing = _days[date];
    if (existing != null && existing.kwh > kwh) return false;
    final rate = existing != null && existing.kwh > 0
        ? existing.costUgx / existing.kwh
        : ratePerKwh;
    _days[date] = DailyEnergy(
      date: date,
      kwh: kwh,
      costUgx: kwh * rate,
      lastRegisterKwh: registerKwh,
      firstAt: firstAt,
      lastAt: lastAt,
    );
    _prune();
    return true;
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
      'date,kwh,cost_ugx,first_reading,last_reading,complete',
      for (final d in _days.values)
        [
          d.date,
          d.kwh.toStringAsFixed(2),
          d.costUgx.toStringAsFixed(0),
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
