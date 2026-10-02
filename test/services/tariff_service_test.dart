import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_automix/constants/uedcl_tariffs.dart';
import 'package:smart_automix/services/tariff_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('starts on the small-industrial default and is stale until confirmed',
      () async {
    final tariff = TariffService();
    await tariff.init();

    expect(tariff.category, UedclTariffCategory.smallIndustrial);
    expect(tariff.ratePerKwh,
        UedclTariffCategory.smallIndustrial.defaultRatePerKwh);
    expect(tariff.lastUpdated, isNull);
    expect(tariff.isStale, isTrue);
  });

  test('confirmTariff saves everything and clears staleness', () async {
    final tariff = TariffService();
    await tariff.init();

    await tariff.confirmTariff(
      category: UedclTariffCategory.commercial,
      ratePerKwh: 700,
      monthlyFixedCharge: 3360,
      dailyCostAlertThreshold: 50000,
    );

    expect(tariff.isStale, isFalse);

    // A fresh instance reads the same values back from storage.
    final reloaded = TariffService();
    await reloaded.init();
    expect(reloaded.category, UedclTariffCategory.commercial);
    expect(reloaded.ratePerKwh, 700);
    expect(reloaded.monthlyFixedCharge, 3360);
    expect(reloaded.dailyCostAlertThreshold, 50000);
    expect(reloaded.isStale, isFalse);
  });

  test('clearing the alert threshold removes it from storage', () async {
    final tariff = TariffService();
    await tariff.init();
    await tariff.confirmTariff(
      category: UedclTariffCategory.domestic,
      ratePerKwh: 250,
      monthlyFixedCharge: 0,
      dailyCostAlertThreshold: 1000,
    );
    await tariff.confirmTariff(
      category: UedclTariffCategory.domestic,
      ratePerKwh: 250,
      monthlyFixedCharge: 0,
    );

    final reloaded = TariffService();
    await reloaded.init();
    expect(reloaded.dailyCostAlertThreshold, isNull);
  });

  test('a rate confirmed over 90 days ago is stale', () async {
    SharedPreferences.setMockInitialValues({
      'tariff_last_updated':
          DateTime.now().subtract(const Duration(days: 91)).toIso8601String(),
    });
    final tariff = TariffService();
    await tariff.init();
    expect(tariff.isStale, isTrue);
  });

  test('a rate confirmed recently is not stale', () async {
    SharedPreferences.setMockInitialValues({
      'tariff_last_updated':
          DateTime.now().subtract(const Duration(days: 30)).toIso8601String(),
    });
    final tariff = TariffService();
    await tariff.init();
    expect(tariff.isStale, isFalse);
  });

  test('costs use the rate, and the monthly bill adds the fixed charge',
      () async {
    final tariff = TariffService();
    await tariff.init();
    await tariff.confirmTariff(
      category: UedclTariffCategory.smallIndustrial,
      ratePerKwh: 500,
      monthlyFixedCharge: 10000,
    );

    expect(tariff.costFor(10), 5000);
    expect(
      tariff.monthlyCostFor(10),
      10 * TariffService.daysPerMonth * 500 + 10000,
    );
  });
}
