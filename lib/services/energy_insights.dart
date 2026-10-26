import '../models/energy_prices.dart';
import 'energy_log.dart';

/// Grid energy over a set of days, split by time-of-use period.
class TouSummary {
  TouSummary._(this.kwh, this.days, this.potentialSavingUgx);

  /// kWh in each period.
  final Map<TouBand, double> kwh;

  /// Days that had hourly figures (others can't be split).
  final int days;

  /// What moving the peak-period energy to off-peak would have saved, at
  /// the current rates.
  final double potentialSavingUgx;

  double get totalKwh => kwh.values.fold(0.0, (a, b) => a + b);

  double shareOf(TouBand band) =>
      totalKwh == 0 ? 0 : (kwh[band] ?? 0) / totalKwh;

  /// Split [days]' grid energy by [tou]'s periods. Null when time-of-use is
  /// off or no day has hourly figures.
  static TouSummary? of(Iterable<DailyEnergy> days, TimeOfUse tou) {
    if (!tou.enabled) return null;
    final kwh = {for (final band in TouBand.values) band: 0.0};
    var counted = 0;
    for (final day in days) {
      final hourly = day.gridHourlyKwh;
      if (hourly == null) continue;
      counted++;
      for (var h = 0; h < 24; h++) {
        kwh[tou.bandAtHour(h)] = kwh[tou.bandAtHour(h)]! + hourly[h];
      }
    }
    if (counted == 0) return null;
    final saving = (kwh[TouBand.peak]! * (tou.peakRate - tou.offPeakRate))
        .clamp(0.0, double.infinity);
    return TouSummary._(kwh, counted, saving);
  }
}

/// Generator use against grid energy over a set of days.
class GeneratorSummary {
  GeneratorSummary._({
    required this.generatorKwh,
    required this.generatorCostUgx,
    required this.generatorSeconds,
    required this.gridKwh,
    required this.gridCostUgx,
    required this.daysUsed,
  });

  final double generatorKwh;
  final double generatorCostUgx;
  final int generatorSeconds;
  final double gridKwh;
  final double gridCostUgx;

  /// Days the generator ran at all.
  final int daysUsed;

  double get generatorHours => generatorSeconds / 3600;

  /// Average grid cost per kWh over the same days, or null without grid
  /// energy.
  double? get gridCostPerKwh => gridKwh > 0 ? gridCostUgx / gridKwh : null;

  /// Null when the generator didn't run in [days].
  static GeneratorSummary? of(Iterable<DailyEnergy> days) {
    var genKwh = 0.0, genCost = 0.0, gridKwh = 0.0, gridCost = 0.0;
    var seconds = 0, used = 0;
    for (final d in days) {
      genKwh += d.generatorKwh;
      genCost += d.generatorCostUgx;
      seconds += d.generatorSeconds;
      gridKwh += d.gridKwh;
      gridCost += d.gridCostUgx;
      if (d.generatorKwh > 0 || d.generatorSeconds > 0) used++;
    }
    if (used == 0) return null;
    return GeneratorSummary._(
      generatorKwh: genKwh,
      generatorCostUgx: genCost,
      generatorSeconds: seconds,
      gridKwh: gridKwh,
      gridCostUgx: gridCost,
      daysUsed: used,
    );
  }
}
