import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/uedcl_tariffs.dart';
import '../models/energy_prices.dart';

/// Tracks which UEDCL tariff category the facility is billed under and the
/// current rate (UGX/kWh), so machine running costs can be estimated.
///
/// The rate is user-editable because ERA/UEDCL tariffs change quarterly and
/// this app has no live feed into UEDCL's billing systems.
///
/// Also holds the time-of-use periods (if the bill has them) and what
/// generator energy costs in fuel, so it can price energy by the hour and
/// by source ([EnergyPrices]).
class TariffService extends ChangeNotifier implements EnergyPrices {
  static const _categoryKey = 'tariff_category';
  static const _rateKey = 'tariff_rate_ugx_per_kwh';
  static const _fixedChargeKey = 'tariff_fixed_charge_ugx';
  static const _lastUpdatedKey = 'tariff_last_updated';
  static const _costThresholdKey = 'tariff_daily_cost_alert_threshold_ugx';
  static const _timeOfUseKey = 'tariff_time_of_use';
  static const _generatorKey = 'generator_cost';

  /// ERA/UEDCL tariffs are reviewed roughly every quarter, so a rate the
  /// user hasn't touched in longer than this is worth flagging as possibly
  /// outdated.
  static const staleAfter = Duration(days: 90);

  /// Billing days per month used for monthly estimates.
  static const daysPerMonth = 30;

  UedclTariffCategory _category = UedclTariffCategory.smallIndustrial;
  double _ratePerKwh = UedclTariffCategory.smallIndustrial.defaultRatePerKwh;
  double _monthlyFixedCharge = 0.0;
  DateTime? _lastUpdated;
  double? _dailyCostAlertThreshold;
  TimeOfUse? _timeOfUse;
  GeneratorCost _generator = const GeneratorCost();

  UedclTariffCategory get category => _category;

  /// Time-of-use periods and rates; disabled (a flat [ratePerKwh]) unless
  /// the user turned them on.
  TimeOfUse get timeOfUse => _timeOfUse ?? TimeOfUse.off(_ratePerKwh);

  GeneratorCost get generator => _generator;

  /// The grid rate at [time]: the time-of-use rate for that hour, or the
  /// standard rate.
  @override
  double gridRateAt(DateTime time) {
    final tou = timeOfUse;
    return tou.rateFor(tou.bandAt(time), _ratePerKwh);
  }

  @override
  double get generatorRatePerKwh => _generator.costPerKwh;
  double get ratePerKwh => _ratePerKwh;
  double get monthlyFixedCharge => _monthlyFixedCharge;
  DateTime? get lastUpdated => _lastUpdated;
  double? get dailyCostAlertThreshold => _dailyCostAlertThreshold;

  /// Whether the tariff rate hasn't been confirmed/updated within the last
  /// [staleAfter] window (or has never been set at all).
  bool get isStale =>
      _lastUpdated == null ||
      DateTime.now().difference(_lastUpdated!) > staleAfter;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final storedCategory = prefs.getString(_categoryKey);
    if (storedCategory != null) {
      _category = UedclTariffCategoryX.fromName(storedCategory);
    }
    _ratePerKwh = prefs.getDouble(_rateKey) ?? _category.defaultRatePerKwh;
    _monthlyFixedCharge = prefs.getDouble(_fixedChargeKey) ?? 0.0;
    _dailyCostAlertThreshold = prefs.getDouble(_costThresholdKey);
    final lastUpdatedIso = prefs.getString(_lastUpdatedKey);
    _lastUpdated =
        lastUpdatedIso != null ? DateTime.tryParse(lastUpdatedIso) : null;
    _timeOfUse = _decode(prefs.getString(_timeOfUseKey), TimeOfUse.fromJson);
    _generator =
        _decode(prefs.getString(_generatorKey), GeneratorCost.fromJson) ??
            const GeneratorCost();
    notifyListeners();
  }

  static T? _decode<T>(String? json, T? Function(Object?) fromJson) {
    if (json == null) return null;
    try {
      return fromJson(jsonDecode(json));
    } on FormatException {
      return null;
    }
  }

  /// Save the time-of-use periods and rates from the bill.
  Future<void> saveTimeOfUse(TimeOfUse timeOfUse) async {
    final problem = timeOfUse.validate();
    if (problem != null) throw ArgumentError(problem);
    _timeOfUse = timeOfUse;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_timeOfUseKey, jsonEncode(timeOfUse.toJson()));
    notifyListeners();
  }

  /// Save the generator's fuel price and consumption.
  Future<void> saveGenerator(GeneratorCost generator) async {
    _generator = generator;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_generatorKey, jsonEncode(generator.toJson()));
    notifyListeners();
  }

  /// Save the tariff the user has confirmed against their current UEDCL
  /// bill. This is the only way to mark the rate as confirmed (resetting
  /// [isStale]) — browsing categories in the UI must not count as
  /// confirming a placeholder default rate.
  Future<void> confirmTariff({
    required UedclTariffCategory category,
    required double ratePerKwh,
    required double monthlyFixedCharge,
    double? dailyCostAlertThreshold,
  }) async {
    _category = category;
    _ratePerKwh = ratePerKwh;
    _monthlyFixedCharge = monthlyFixedCharge;
    _dailyCostAlertThreshold = dailyCostAlertThreshold;
    _lastUpdated = DateTime.now();
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_categoryKey, _category.name);
    await prefs.setDouble(_rateKey, _ratePerKwh);
    await prefs.setDouble(_fixedChargeKey, _monthlyFixedCharge);
    if (_lastUpdated != null) {
      await prefs.setString(_lastUpdatedKey, _lastUpdated!.toIso8601String());
    }
    if (_dailyCostAlertThreshold != null) {
      await prefs.setDouble(_costThresholdKey, _dailyCostAlertThreshold!);
    } else {
      await prefs.remove(_costThresholdKey);
    }
  }

  /// Estimate the UGX cost of consuming [kWh] of energy at the current rate.
  double costFor(double kWh) => kWh * _ratePerKwh;

  /// Estimate a monthly UEDCL bill for a facility using [dailyKWh] per day:
  /// energy over [daysPerMonth] days plus the monthly fixed charge.
  double monthlyCostFor(double dailyKWh) =>
      costFor(dailyKWh * daysPerMonth) + _monthlyFixedCharge;
}

final tariffService = TariffService();
