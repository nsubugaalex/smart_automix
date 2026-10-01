import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/uedcl_tariffs.dart';

/// Tracks which UEDCL tariff category the facility is billed under and the
/// current rate (UGX/kWh), so machine running costs can be estimated.
///
/// The rate is user-editable because ERA/UEDCL tariffs change quarterly and
/// this app has no live feed into UEDCL's billing systems.
class TariffService extends ChangeNotifier {
  static final TariffService _instance = TariffService._internal();
  factory TariffService() => _instance;
  TariffService._internal();

  static const _categoryKey = 'tariff_category';
  static const _rateKey = 'tariff_rate_ugx_per_kwh';
  static const _fixedChargeKey = 'tariff_fixed_charge_ugx';
  static const _lastUpdatedKey = 'tariff_last_updated';
  static const _costThresholdKey = 'tariff_daily_cost_alert_threshold_ugx';

  /// ERA/UEDCL tariffs are reviewed roughly every quarter, so a rate the
  /// user hasn't touched in longer than this is worth flagging as possibly
  /// outdated.
  static const staleAfter = Duration(days: 90);

  UedclTariffCategory _category = UedclTariffCategory.smallIndustrial;
  double _ratePerKwh = UedclTariffCategory.smallIndustrial.defaultRatePerKwh;
  double _monthlyFixedCharge = 0.0;
  DateTime? _lastUpdated;
  double? _dailyCostAlertThreshold;

  UedclTariffCategory get category => _category;
  double get ratePerKwh => _ratePerKwh;
  double get monthlyFixedCharge => _monthlyFixedCharge;
  DateTime? get lastUpdated => _lastUpdated;
  double? get dailyCostAlertThreshold => _dailyCostAlertThreshold;

  /// Whether the tariff rate hasn't been confirmed/updated within the last
  /// [staleAfter] window (or has never been set at all).
  bool get isStale =>
      _lastUpdated == null || DateTime.now().difference(_lastUpdated!) > staleAfter;

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
    _lastUpdated = lastUpdatedIso != null ? DateTime.tryParse(lastUpdatedIso) : null;
    notifyListeners();
  }

  /// Switch tariff category. Resets the rate to that category's default
  /// unless [keepCustomRate] is true.
  Future<void> setCategory(UedclTariffCategory category, {bool keepCustomRate = false}) async {
    _category = category;
    if (!keepCustomRate) {
      _ratePerKwh = category.defaultRatePerKwh;
    }
    _lastUpdated = DateTime.now();
    await _persist();
    notifyListeners();
  }

  Future<void> setRatePerKwh(double rate) async {
    _ratePerKwh = rate;
    _lastUpdated = DateTime.now();
    await _persist();
    notifyListeners();
  }

  Future<void> setMonthlyFixedCharge(double charge) async {
    _monthlyFixedCharge = charge;
    await _persist();
    notifyListeners();
  }

  /// Set (or clear, with null) the daily-cost level above which the user
  /// wants to be alerted.
  Future<void> setDailyCostAlertThreshold(double? threshold) async {
    _dailyCostAlertThreshold = threshold;
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
}

final tariffService = TariffService();
