import 'package:flutter_test/flutter_test.dart';
import 'package:smart_automix/models/energy_prices.dart';
import 'package:smart_automix/models/prepaid.dart';
import 'package:smart_automix/services/energy_log.dart';

void main() {
  /// A log with [kwhPerHour] of grid energy every hour of the given days of
  /// October, as the panel would report them.
  EnergyLog logOf(List<int> days,
      {double kwhPerHour = 1, double generator = 0}) {
    final log = EnergyLog();
    for (final d in days) {
      log.applyPanelDay(
        date: '2026-10-${d.toString().padLeft(2, '0')}',
        kwh: kwhPerHour * 24 + generator,
        registerKwh: 1000.0 + d,
        firstAt: DateTime(2026, 10, d, 0, 0, 5),
        lastAt: DateTime(2026, 10, d, 23, 59, 55),
        gridHourlyKwh: List.filled(24, kwhPerHour),
        generatorKwh: generator,
        prices: const FlatPrices(600),
      );
    }
    return log;
  }

  PrepaidEntry reading(DateTime at, double units) => PrepaidEntry(
      id: 'r$at', kind: PrepaidEntryKind.reading, at: at, units: units);
  PrepaidEntry purchase(DateTime at, double units, {double? ugx}) =>
      PrepaidEntry(
          id: 'p$at',
          kind: PrepaidEntryKind.purchase,
          at: at,
          units: units,
          amountUgx: ugx);

  group('grid energy since a time', () {
    test('rest of the start day by the hour, then whole days', () {
      final log = logOf([20, 21, 22]);
      // From 20 Oct 18:30: half of hour 18 + hours 19-23 = 5.5, then 48.
      expect(
          PrepaidCalculator.gridKwhSince(log, DateTime(2026, 10, 20, 18, 30)),
          closeTo(5.5 + 48, 1e-9));
    });

    test('generator energy is not taken off the Yaka credit', () {
      final log = logOf([21], generator: 10);
      expect(PrepaidCalculator.gridKwhSince(log, DateTime(2026, 10, 21)),
          closeTo(24, 1e-9));
    });
  });

  group('balance', () {
    final now = DateTime(2026, 10, 23, 12);

    test('reading + purchases since - energy used since', () {
      final log = logOf([16, 17, 18, 19, 20, 21, 22, 23], kwhPerHour: 2);
      final b = PrepaidCalculator.balance(
        entries: [
          purchase(DateTime(2026, 10, 15), 999), // before the reading
          reading(DateTime(2026, 10, 21), 100),
          purchase(DateTime(2026, 10, 22, 9), 200, ugx: 140000),
        ],
        log: log,
        now: now,
        estimatedDailyKwh: 10,
      )!;
      // Used since 21 Oct 00:00: 21st, 22nd and today so far (48+48+48).
      expect(b.usedKwh, closeTo(144, 1e-9));
      expect(b.units, closeTo(100 + 200 - 144, 1e-9));
      expect(b.measured, isTrue);
      expect(b.dailyKwh, closeTo(48, 1e-9), reason: 'last 7 complete days');
      expect(b.daysLeft, closeTo(156 / 48, 1e-9));
    });

    test('without a supply meter, it estimates from machine ratings', () {
      final b = PrepaidCalculator.balance(
        entries: [reading(DateTime(2026, 10, 21, 12), 100)],
        log: EnergyLog(),
        now: now,
        estimatedDailyKwh: 20,
      )!;
      expect(b.measured, isFalse);
      expect(b.usedKwh, closeTo(40, 1e-9));
      expect(b.daysLeft, closeTo(3, 1e-9));
    });

    test('nothing to go on before the first meter reading', () {
      expect(
          PrepaidCalculator.balance(
            entries: [purchase(DateTime(2026, 10, 21), 100)],
            log: EnergyLog(),
            now: now,
            estimatedDailyKwh: 20,
          ),
          isNull);
    });

    test('an overdrawn estimate reports zero days', () {
      final b = PrepaidCalculator.balance(
        entries: [reading(DateTime(2026, 10, 22), 10)],
        log: logOf([20, 21, 22, 23]),
        now: now,
        estimatedDailyKwh: 0,
      )!;
      expect(b.units, lessThan(0));
      expect(b.daysLeft, 0);
    });
  });

  test('average price paid per unit', () {
    expect(
        PrepaidCalculator.averagePrice([
          purchase(DateTime(2026, 10, 1), 100, ugx: 75000),
          purchase(DateTime(2026, 10, 9), 300, ugx: 205000),
          purchase(DateTime(2026, 10, 12), 50), // amount not entered
        ]),
        closeTo(700, 1e-9));
    expect(PrepaidCalculator.averagePrice([]), isNull);
  });

  test('entries round-trip through JSON', () {
    final e = purchase(DateTime(2026, 10, 9, 14, 30), 300, ugx: 205000);
    final copy = PrepaidEntry.fromJson(e.toJson())!;
    expect(copy.toJson(), e.toJson());
    expect(PrepaidEntry.fromJson({'kind': 'gift'}), isNull);
  });
}
