import 'package:flutter/foundation.dart';

/// What energy costs at a given moment: grid energy at the tariff rate in
/// force then (which varies with [TimeOfUse]), generator energy at fuel cost.
abstract interface class EnergyPrices {
  /// UGX per kWh for grid energy used at [time].
  double gridRateAt(DateTime time);

  /// UGX per kWh for energy from the standby generator.
  double get generatorRatePerKwh;
}

/// One grid rate at all hours, and a fixed generator rate.
class FlatPrices implements EnergyPrices {
  const FlatPrices(this.ratePerKwh, {this.generatorRatePerKwh = 0});

  final double ratePerKwh;

  @override
  final double generatorRatePerKwh;

  @override
  double gridRateAt(DateTime time) => ratePerKwh;
}

/// Time-of-use periods on a UEDCL bill.
enum TouBand { offPeak, shoulder, peak }

extension TouBandX on TouBand {
  String get label => switch (this) {
        TouBand.offPeak => 'Off-peak',
        TouBand.shoulder => 'Shoulder',
        TouBand.peak => 'Peak',
      };
}

/// A time-of-use tariff: a peak and an off-peak window with their own
/// rates; every other hour is shoulder, billed at the tariff's standard
/// rate. Hours are local time; an end of 24 means midnight, and a window
/// may run past midnight (e.g. 22 to 6).
///
/// The default hours follow ERA's time-of-use periods for industrial
/// customers (peak 18:00-24:00, off-peak 00:00-06:00), but check them and
/// the rates against your own bill.
@immutable
class TimeOfUse {
  const TimeOfUse({
    this.enabled = false,
    required this.peakRate,
    required this.offPeakRate,
    this.peakStart = 18,
    this.peakEnd = 24,
    this.offPeakStart = 0,
    this.offPeakEnd = 6,
  });

  /// Time-of-use off, with both rates at [standardRate] until the user
  /// enters the ones on their bill.
  factory TimeOfUse.off(double standardRate) =>
      TimeOfUse(peakRate: standardRate, offPeakRate: standardRate);

  final bool enabled;
  final double peakRate;
  final double offPeakRate;
  final int peakStart;
  final int peakEnd;
  final int offPeakStart;
  final int offPeakEnd;

  static bool _inWindow(int hour, int start, int end) =>
      start < end ? hour >= start && hour < end : hour >= start || hour < end;

  /// The period [hour] (0-23) falls in; always shoulder when disabled.
  TouBand bandAtHour(int hour) {
    if (!enabled) return TouBand.shoulder;
    if (_inWindow(hour, peakStart, peakEnd)) return TouBand.peak;
    if (_inWindow(hour, offPeakStart, offPeakEnd)) return TouBand.offPeak;
    return TouBand.shoulder;
  }

  TouBand bandAt(DateTime time) => bandAtHour(time.hour);

  /// The rate for [band], with shoulder at [standardRate].
  double rateFor(TouBand band, double standardRate) => switch (band) {
        TouBand.peak => peakRate,
        TouBand.offPeak => offPeakRate,
        TouBand.shoulder => standardRate,
      };

  /// When the period after [time] begins.
  DateTime nextChange(DateTime time) {
    final band = bandAt(time);
    var next = DateTime(time.year, time.month, time.day, time.hour + 1);
    for (var i = 0; i < 24 && bandAt(next) == band; i++) {
      next = DateTime(next.year, next.month, next.day, next.hour + 1);
    }
    return next;
  }

  /// The first hour of the next [band] window at or after [time].
  DateTime nextStartOf(TouBand band, DateTime time) {
    var t = DateTime(time.year, time.month, time.day, time.hour);
    for (var i = 0; i < 48; i++) {
      if (bandAt(t) == band) return t;
      t = DateTime(t.year, t.month, t.day, t.hour + 1);
    }
    return t;
  }

  /// A problem with the windows, or null if they're usable.
  String? validate() {
    bool valid(int start, int end) =>
        start >= 0 && start <= 23 && end >= 1 && end <= 24 && start != end;
    if (!valid(peakStart, peakEnd)) return 'Peak hours are not valid';
    if (!valid(offPeakStart, offPeakEnd)) return 'Off-peak hours are not valid';
    for (var h = 0; h < 24; h++) {
      if (_inWindow(h, peakStart, peakEnd) &&
          _inWindow(h, offPeakStart, offPeakEnd)) {
        return 'Peak and off-peak hours overlap';
      }
    }
    return null;
  }

  TimeOfUse copyWith({
    bool? enabled,
    double? peakRate,
    double? offPeakRate,
    int? peakStart,
    int? peakEnd,
    int? offPeakStart,
    int? offPeakEnd,
  }) =>
      TimeOfUse(
        enabled: enabled ?? this.enabled,
        peakRate: peakRate ?? this.peakRate,
        offPeakRate: offPeakRate ?? this.offPeakRate,
        peakStart: peakStart ?? this.peakStart,
        peakEnd: peakEnd ?? this.peakEnd,
        offPeakStart: offPeakStart ?? this.offPeakStart,
        offPeakEnd: offPeakEnd ?? this.offPeakEnd,
      );

  Map<String, Object> toJson() => {
        'enabled': enabled,
        'peakRate': peakRate,
        'offPeakRate': offPeakRate,
        'peakStart': peakStart,
        'peakEnd': peakEnd,
        'offPeakStart': offPeakStart,
        'offPeakEnd': offPeakEnd,
      };

  static TimeOfUse? fromJson(Object? json) {
    if (json is! Map) return null;
    final peakRate = json['peakRate'];
    final offPeakRate = json['offPeakRate'];
    if (peakRate is! num || offPeakRate is! num) return null;
    int hour(String key, int fallback) =>
        json[key] is int ? json[key] as int : fallback;
    final tou = TimeOfUse(
      enabled: json['enabled'] == true,
      peakRate: peakRate.toDouble(),
      offPeakRate: offPeakRate.toDouble(),
      peakStart: hour('peakStart', 18),
      peakEnd: hour('peakEnd', 24),
      offPeakStart: hour('offPeakStart', 0),
      offPeakEnd: hour('offPeakEnd', 6),
    );
    return tou.validate() == null ? tou : null;
  }
}

/// What a kWh from the standby generator costs in fuel.
@immutable
class GeneratorCost {
  const GeneratorCost({
    this.fuelPricePerLitre = defaultFuelPrice,
    this.litresPerKwh = defaultLitresPerKwh,
  });

  /// Placeholders: a pump price for diesel and a typical small diesel
  /// generator at moderate load. Replace both with your own figures; a
  /// lightly loaded generator uses noticeably more fuel per kWh.
  static const defaultFuelPrice = 5000.0;
  static const defaultLitresPerKwh = 0.35;

  final double fuelPricePerLitre;
  final double litresPerKwh;

  double get costPerKwh => fuelPricePerLitre * litresPerKwh;

  Map<String, Object> toJson() =>
      {'fuelPrice': fuelPricePerLitre, 'litresPerKwh': litresPerKwh};

  static GeneratorCost? fromJson(Object? json) {
    if (json is! Map) return null;
    final price = json['fuelPrice'];
    final litres = json['litresPerKwh'];
    if (price is! num || litres is! num || price <= 0 || litres <= 0) {
      return null;
    }
    return GeneratorCost(
        fuelPricePerLitre: price.toDouble(), litresPerKwh: litres.toDouble());
  }
}
