import 'package:flutter/foundation.dart';

import '../services/energy_log.dart';

enum PrepaidEntryKind {
  /// A token loaded onto the meter.
  purchase,

  /// The units left as shown on the Yaka meter.
  reading,
}

/// A token bought, or a reading of the meter's balance.
@immutable
class PrepaidEntry {
  const PrepaidEntry({
    required this.id,
    required this.kind,
    required this.at,
    required this.units,
    this.amountUgx,
  });

  final String id;
  final PrepaidEntryKind kind;
  final DateTime at;

  /// kWh: added by a purchase, or left on the meter for a reading.
  final double units;

  /// What a purchase cost.
  final double? amountUgx;

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'at': at.millisecondsSinceEpoch,
        'units': units,
        'amount': amountUgx,
      };

  static PrepaidEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = PrepaidEntryKind.values
        .where((k) => k.name == json['kind'])
        .firstOrNull;
    final id = json['id'], at = json['at'], units = json['units'];
    if (kind == null || id is! String || at is! int || units is! num) {
      return null;
    }
    final amount = json['amount'];
    return PrepaidEntry(
      id: id,
      kind: kind,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      units: units.toDouble(),
      amountUgx: amount is num ? amount.toDouble() : null,
    );
  }
}

/// The credit estimate: what's left on the meter and how long it lasts.
@immutable
class PrepaidBalance {
  const PrepaidBalance({
    required this.units,
    required this.since,
    required this.usedKwh,
    required this.dailyKwh,
    required this.measured,
  });

  /// Estimated units (kWh) left; may go below zero if the estimate has
  /// drifted, which means the meter should be read again.
  final double units;

  /// The meter reading the estimate counts from.
  final DateTime since;

  /// Grid energy used since then.
  final double usedKwh;

  /// Usual daily grid use; null if unknown.
  final double? dailyKwh;

  /// Whether the use comes from the panel's meter (true) or from machine
  /// ratings (false).
  final bool measured;

  /// Days of credit left at the usual daily use; null if unknown.
  double? get daysLeft => dailyKwh == null || dailyKwh! <= 0
      ? null
      : (units < 0 ? 0 : units) / dailyKwh!;
}

/// Works out the balance from the entries and the metered energy.
class PrepaidCalculator {
  const PrepaidCalculator._();

  /// Days of history used for the usual daily use.
  static const usageDays = 7;

  /// Grid kWh in [log] since [from] up to the latest reading: whole days
  /// after it, plus the rest of its own day (by the hour where the panel
  /// reports hourly figures, otherwise in proportion to the time covered).
  static double gridKwhSince(EnergyLog log, DateTime from) {
    final fromKey = EnergyLog.dateKey(from);
    var total = 0.0;
    for (final day in log.days) {
      final cmp = day.date.compareTo(fromKey);
      if (cmp < 0) continue;
      if (cmp > 0) {
        total += day.gridKwh;
        continue;
      }
      final hourly = day.gridHourlyKwh;
      if (hourly != null) {
        for (var h = from.hour + 1; h < 24; h++) {
          total += hourly[h];
        }
        total += hourly[from.hour] * (1 - from.minute / 60);
      } else if (day.lastAt.isAfter(from)) {
        final covered = day.lastAt.difference(day.firstAt).inSeconds;
        final after = day.lastAt
            .difference(from.isAfter(day.firstAt) ? from : day.firstAt)
            .inSeconds;
        total += covered <= 0 ? day.gridKwh : day.gridKwh * after / covered;
      }
    }
    return total;
  }

  /// Average daily grid use over the last [usageDays] complete days before
  /// [now] that have readings; null if there are none.
  static double? measuredDailyKwh(EnergyLog log, DateTime now) {
    final today = EnergyLog.dateKey(now);
    final days = log.days
        .where((d) => d.date.compareTo(today) < 0 && d.isCompleteAt(now))
        .toList();
    if (days.isEmpty) return null;
    final recent =
        days.length > usageDays ? days.sublist(days.length - usageDays) : days;
    return recent.fold(0.0, (s, d) => s + d.gridKwh) / recent.length;
  }

  /// The balance from the latest reading, adding purchases since and
  /// taking off the energy used since; null without any reading.
  static PrepaidBalance? balance({
    required List<PrepaidEntry> entries,
    required EnergyLog log,
    required DateTime now,
    required double estimatedDailyKwh,
  }) {
    final readings = entries
        .where((e) => e.kind == PrepaidEntryKind.reading)
        .toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    if (readings.isEmpty) return null;
    final anchor = readings.last;
    final bought = entries
        .where((e) =>
            e.kind == PrepaidEntryKind.purchase && !e.at.isBefore(anchor.at))
        .fold(0.0, (s, e) => s + e.units);

    final measuredDaily = measuredDailyKwh(log, now);
    final measured = !log.isEmpty && measuredDaily != null;
    final double used;
    if (measured) {
      used = gridKwhSince(log, anchor.at);
    } else {
      used =
          estimatedDailyKwh * now.difference(anchor.at).inMinutes / (24 * 60);
    }
    return PrepaidBalance(
      units: anchor.units + bought - used,
      since: anchor.at,
      usedKwh: used,
      dailyKwh: measured ? measuredDaily : estimatedDailyKwh,
      measured: measured,
    );
  }

  /// Average price paid per unit over purchases with an amount; null if
  /// none.
  static double? averagePrice(List<PrepaidEntry> entries) {
    final paid = entries.where((e) =>
        e.kind == PrepaidEntryKind.purchase &&
        e.amountUgx != null &&
        e.units > 0);
    if (paid.isEmpty) return null;
    final units = paid.fold(0.0, (s, e) => s + e.units);
    final ugx = paid.fold(0.0, (s, e) => s + e.amountUgx!);
    return ugx / units;
  }
}
