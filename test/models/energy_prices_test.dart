import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_automix/models/energy_prices.dart';
import 'package:smart_automix/services/tariff_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TimeOfUse', () {
    const tou = TimeOfUse(enabled: true, peakRate: 1000, offPeakRate: 300);

    test('default windows: off-peak 0-6, peak 18-24, shoulder between', () {
      expect(tou.bandAtHour(0), TouBand.offPeak);
      expect(tou.bandAtHour(5), TouBand.offPeak);
      expect(tou.bandAtHour(6), TouBand.shoulder);
      expect(tou.bandAtHour(17), TouBand.shoulder);
      expect(tou.bandAtHour(18), TouBand.peak);
      expect(tou.bandAtHour(23), TouBand.peak);
    });

    test('disabled means shoulder (the standard rate) at every hour', () {
      final off = tou.copyWith(enabled: false);
      expect(
          {for (var h = 0; h < 24; h++) off.bandAtHour(h)}, {TouBand.shoulder});
    });

    test('windows can run past midnight', () {
      final night = tou.copyWith(
          peakStart: 17, peakEnd: 21, offPeakStart: 22, offPeakEnd: 5);
      expect(night.validate(), isNull);
      expect(night.bandAtHour(23), TouBand.offPeak);
      expect(night.bandAtHour(2), TouBand.offPeak);
      expect(night.bandAtHour(21), TouBand.shoulder);
    });

    test('overlapping or empty windows are rejected', () {
      expect(tou.copyWith(offPeakStart: 10, offPeakEnd: 19).validate(),
          contains('overlap'));
      expect(tou.copyWith(peakStart: 18, peakEnd: 18).validate(), isNotNull);
    });

    test('next change and next off-peak start', () {
      final evening = DateTime(2026, 10, 7, 19, 30);
      expect(tou.nextChange(evening), DateTime(2026, 10, 8));
      expect(tou.nextStartOf(TouBand.offPeak, evening), DateTime(2026, 10, 8));
      expect(
          tou.nextChange(DateTime(2026, 10, 7, 9)), DateTime(2026, 10, 7, 18));
    });

    test('JSON round trip; invalid JSON is ignored', () {
      final copy = TimeOfUse.fromJson(tou.toJson())!;
      expect(copy.enabled, isTrue);
      expect(copy.peakRate, 1000);
      expect(TimeOfUse.fromJson({'peakRate': 1}), isNull);
    });
  });

  test('generator cost per kWh is fuel price times litres per kWh', () {
    expect(
        const GeneratorCost(fuelPricePerLitre: 5200, litresPerKwh: 0.4)
            .costPerKwh,
        closeTo(2080, 1e-9));
  });

  test('TariffService prices the grid by time of use and saves it', () async {
    SharedPreferences.setMockInitialValues({});
    var tariff = TariffService();
    await tariff.init();
    final standard = tariff.ratePerKwh;
    expect(tariff.gridRateAt(DateTime(2026, 10, 7, 19)), standard,
        reason: 'flat until time of use is turned on');

    await tariff.saveTimeOfUse(
        const TimeOfUse(enabled: true, peakRate: 900, offPeakRate: 350));
    await tariff.saveGenerator(
        const GeneratorCost(fuelPricePerLitre: 5000, litresPerKwh: 0.3));

    tariff = TariffService();
    await tariff.init();
    expect(tariff.gridRateAt(DateTime(2026, 10, 7, 19)), 900);
    expect(tariff.gridRateAt(DateTime(2026, 10, 7, 3)), 350);
    expect(tariff.gridRateAt(DateTime(2026, 10, 7, 12)), standard);
    expect(tariff.generatorRatePerKwh, closeTo(1500, 1e-9));

    expect(
        () => tariff.saveTimeOfUse(const TimeOfUse(
            enabled: true,
            peakRate: 1,
            offPeakRate: 1,
            offPeakStart: 18,
            offPeakEnd: 20)),
        throwsArgumentError);
  });
}
