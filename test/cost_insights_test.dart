import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_automix/models/energy_prices.dart';
import 'package:smart_automix/screens/dashboard/control_actions.dart';
import 'package:smart_automix/screens/settings/tariff_screen.dart';
import 'package:smart_automix/services/energy_insights.dart';
import 'package:smart_automix/services/energy_log.dart';
import 'package:smart_automix/services/tariff_service.dart';
import 'package:smart_automix/widgets/common/cost_insights.dart';

void main() {
  const tou = TimeOfUse(enabled: true, peakRate: 1000, offPeakRate: 400);

  /// A day with [perHour] kWh from the grid every hour, and [generator] kWh
  /// over [generatorHours] hours from the generator.
  DailyEnergy day(int d,
      {double perHour = 1, double generator = 0, int generatorHours = 0}) {
    final log = EnergyLog()
      ..applyPanelDay(
        date: '2026-10-${d.toString().padLeft(2, '0')}',
        kwh: perHour * 24 + generator,
        registerKwh: 1000,
        firstAt: DateTime(2026, 10, d, 0, 0, 5),
        lastAt: DateTime(2026, 10, d, 23, 59, 55),
        gridHourlyKwh: List.filled(24, perHour),
        generatorKwh: generator,
        generatorSeconds: generatorHours * 3600,
        prices: const FlatPrices(600, generatorRatePerKwh: 1800),
      );
    return log.days.single;
  }

  group('TouSummary', () {
    test('splits grid energy by period and prices the shift', () {
      final s = TouSummary.of([day(1), day(2)], tou)!;
      expect(s.kwh[TouBand.peak], 12); // 18-24, two days
      expect(s.kwh[TouBand.offPeak], 12); // 0-6
      expect(s.kwh[TouBand.shoulder], 24);
      expect(s.shareOf(TouBand.peak), 0.25);
      expect(s.potentialSavingUgx, 12 * (1000 - 400));
    });

    test('is null with time-of-use off or no hourly figures', () {
      expect(TouSummary.of([day(1)], tou.copyWith(enabled: false)), isNull);
      final noHourly = EnergyLog()
        ..applyPanelDay(
          date: '2026-10-01',
          kwh: 10,
          registerKwh: 10,
          firstAt: DateTime(2026, 10, 1),
          lastAt: DateTime(2026, 10, 1, 23),
          prices: const FlatPrices(600),
        );
      expect(TouSummary.of(noHourly.days, tou), isNull);
    });
  });

  group('GeneratorSummary', () {
    test('totals generator use against the grid', () {
      final s = GeneratorSummary.of(
          [day(1, generator: 6, generatorHours: 2), day(2)])!;
      expect(s.generatorKwh, 6);
      expect(s.generatorCostUgx, closeTo(6 * 1800, 1e-6));
      expect(s.generatorHours, 2);
      expect(s.daysUsed, 1);
      expect(s.gridCostPerKwh, closeTo(600, 1e-6));
    });

    test('is null when the generator never ran', () {
      expect(GeneratorSummary.of([day(1), day(2)]), isNull);
    });
  });

  group('peak start cost', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await tariffService.init();
    });

    test('per hour now and off-peak, only at peak time', () async {
      await tariffService.saveTimeOfUse(tou);
      final cost = peakCostOf(7500, DateTime(2026, 10, 7, 19))!;
      expect(cost.nowPerHour, 7500);
      expect(cost.offPeakPerHour, 3000);
      expect(cost.offPeakFrom, DateTime(2026, 10, 8));
      expect(peakCostOf(7500, DateTime(2026, 10, 7, 12)), isNull);
    });

    test('none until the bill rates are entered', () async {
      await tariffService
          .saveTimeOfUse(TimeOfUse.off(600).copyWith(enabled: true));
      expect(peakCostOf(7500, DateTime(2026, 10, 7, 19)), isNull);
    });
  });

  group('cards', () {
    Future<void> show(WidgetTester tester, Widget card) async {
      await tester.binding.setSurfaceSize(const Size(420, 1000));
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: card))));
    }

    testWidgets('time-of-use card: current period and possible saving',
        (tester) async {
      await show(
          tester,
          TimeOfUseCard(
            timeOfUse: tou,
            standardRate: 600,
            summary: TouSummary.of([day(1)], tou),
            now: DateTime(2026, 10, 7, 19, 30),
          ));
      expect(find.textContaining('Peak now'), findsOneWidget);
      expect(find.textContaining('until 00:00'), findsOneWidget);
      expect(find.textContaining('saved about UGX 3,600'), findsOneWidget);
    });

    testWidgets('time-of-use card asks for the bill rates first',
        (tester) async {
      final unset = TimeOfUse.off(600).copyWith(enabled: true);
      await show(
          tester,
          TimeOfUseCard(
            timeOfUse: unset,
            standardRate: 600,
            summary: TouSummary.of([day(1)], unset),
            now: DateTime(2026, 10, 7, 12),
          ));
      expect(find.textContaining('Enter the peak and off-peak rates'),
          findsOneWidget);
    });

    testWidgets('generator card compares the cost with the grid',
        (tester) async {
      await show(
          tester,
          GeneratorCard(
            summary: GeneratorSummary.of([day(1, generator: 6)]),
            onGenerator: true,
            generatorCostPerKwh: 1800,
            gridRateNow: 600,
          ));
      expect(find.text('Running now'), findsOneWidget);
      expect(find.textContaining('generator is 3.0×'), findsOneWidget);
      expect(find.textContaining('6.0 kWh'), findsOneWidget);
    });
  });

  group('Tariff tab', () {
    Future<void> openTariff(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      await tariffService.init();
      await tester.binding.setSurfaceSize(const Size(420, 2600));
      await tester
          .pumpWidget(const MaterialApp(home: Scaffold(body: TariffBody())));
      await tester.pumpAndSettle();
      await tester.tap(find.text('My bill has peak and off-peak rates'));
      await tester.pumpAndSettle();
    }

    testWidgets('saves time-of-use rates and generator fuel cost',
        (tester) async {
      await openTariff(tester);
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Peak rate (UGX/kWh)'), '950');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Off-peak rate (UGX/kWh)'), '380');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Fuel price (UGX/litre)'), '5200');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = tariffService.timeOfUse;
      expect(saved.enabled, isTrue);
      expect(saved.peakRate, 950);
      expect(saved.offPeakRate, 380);
      expect(tariffService.generator.fuelPricePerLitre, 5200);
      expect(tariffService.gridRateAt(DateTime(2026, 10, 7, 20)), 950);
    });

    testWidgets('rejects overlapping peak and off-peak hours', (tester) async {
      await openTariff(tester);
      // Off-peak from 18:00 overlaps peak 18:00-24:00.
      await tester.tap(
          find.widgetWithText(DropdownButtonFormField<int>, 'Off-peak from'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('18:00').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Peak and off-peak hours overlap'), findsOneWidget);
      expect(tariffService.timeOfUse.enabled, isFalse, reason: 'not saved');
    });
  });
}
