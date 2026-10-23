import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_automix/models/energy_prices.dart';
import 'package:smart_automix/services/energy_log.dart';
import 'package:smart_automix/services/panel/panel_link.dart';
import 'package:smart_automix/services/power_monitor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EnergyLog', () {
    late EnergyLog log;
    setUp(() => log = EnergyLog());

    void read(double kwh, DateTime at, {double rate = 1000}) =>
        log.record(registerKwh: kwh, at: at, prices: FlatPrices(rate));

    test('adds each increase to its day, priced at the rate of the time', () {
      read(100, DateTime(2026, 10, 7, 8));
      read(110, DateTime(2026, 10, 7, 12));
      read(115, DateTime(2026, 10, 7, 17), rate: 2000); // rate changed

      final day = log.day(DateTime(2026, 10, 7))!;
      expect(day.kwh, closeTo(15, 1e-9));
      expect(day.costUgx, closeTo(10 * 1000 + 5 * 2000, 1e-6));
      expect(day.firstAt, DateTime(2026, 10, 7, 8));
      expect(day.lastAt, DateTime(2026, 10, 7, 17));
    });

    test('each day counts separately; a meter reset adds nothing', () {
      read(100, DateTime(2026, 10, 7, 23, 50));
      read(101, DateTime(2026, 10, 8, 0, 5));
      read(104, DateTime(2026, 10, 8, 9));
      read(2, DateTime(2026, 10, 8, 10)); // meter replaced
      read(5, DateTime(2026, 10, 8, 11));

      expect(log.day(DateTime(2026, 10, 7))!.kwh, 0);
      expect(log.day(DateTime(2026, 10, 8))!.kwh, closeTo(3 + 3, 1e-9));
    });

    test('lastDays fills days without readings with null', () {
      read(100, DateTime(2026, 10, 5, 9));
      read(110, DateTime(2026, 10, 7, 9));
      final days = log.lastDays(4, DateTime(2026, 10, 7, 15));
      expect(
          days.map((d) => d?.date), [null, '2026-10-05', null, '2026-10-07']);
    });

    test('lastDays crosses month ends', () {
      read(1, DateTime(2026, 9, 30, 9));
      expect(log.lastDays(2, DateTime(2026, 10, 1)).first?.date, '2026-09-30');
    });

    test('a day is complete only if readings reach both midnights', () {
      read(100, DateTime(2026, 10, 7, 0, 5));
      read(150, DateTime(2026, 10, 7, 23, 55));
      read(150, DateTime(2026, 10, 8, 9)); // app opened late
      final now = DateTime(2026, 10, 8, 12);

      expect(log.day(DateTime(2026, 10, 7))!.isCompleteAt(now), isTrue);
      expect(log.day(DateTime(2026, 10, 8))!.isCompleteAt(now), isFalse);

      read(10, DateTime(2026, 10, 9, 0, 1));
      expect(
          log
              .day(DateTime(2026, 10, 9))!
              .isCompleteAt(DateTime(2026, 10, 9, 8)),
          isTrue,
          reason: 'today only needs to be covered since midnight');
    });

    test('keeps at most maxDays, dropping the oldest', () {
      final start = DateTime(2025, 1, 1, 12);
      for (var i = 0; i < EnergyLog.maxDays + 5; i++) {
        read(
            i.toDouble(), DateTime(start.year, start.month, start.day + i, 12));
      }
      expect(log.days, hasLength(EnergyLog.maxDays));
      expect(log.day(start), isNull);
    });

    test('survives a JSON round trip and ignores bad entries', () {
      read(100, DateTime(2026, 10, 7, 8));
      read(112.5, DateTime(2026, 10, 7, 18));
      final copy = EnergyLog.fromJson(log.toJson());
      final day = copy.day(DateTime(2026, 10, 7))!;
      expect(day.kwh, closeTo(12.5, 1e-9));
      expect(day.lastRegisterKwh, 112.5);
      expect(day.lastAt, DateTime(2026, 10, 7, 18));

      expect(EnergyLog.fromJson('not json').isEmpty, isTrue);
      expect(EnergyLog.fromJson('[{"date": "x"}, 5]').isEmpty, isTrue);
    });

    group('panel day totals', () {
      void panelDay(String date, double kwh, double reg,
              {required DateTime first, required DateTime last}) =>
          log.applyPanelDay(
              date: date,
              kwh: kwh,
              registerKwh: reg,
              firstAt: first,
              lastAt: last,
              prices: FlatPrices(1000));

      test('fill a day the app never saw, priced at the current rate', () {
        panelDay('2026-10-06', 80, 1080,
            first: DateTime(2026, 10, 6, 0, 0, 5),
            last: DateTime(2026, 10, 6, 23, 59, 55));
        final day = log.day(DateTime(2026, 10, 6))!;
        expect(day.kwh, 80);
        expect(day.costUgx, 80000);
        expect(day.isCompleteAt(DateTime(2026, 10, 7)), isTrue);
      });

      test("replace the app's partial day, keeping the app's rate", () {
        read(100, DateTime(2026, 10, 6, 9), rate: 800);
        read(130, DateTime(2026, 10, 6, 17), rate: 800); // 30 kWh, 800/kWh
        panelDay('2026-10-06', 75, 140,
            first: DateTime(2026, 10, 6, 0, 0, 5),
            last: DateTime(2026, 10, 6, 23, 59, 55));
        final day = log.day(DateTime(2026, 10, 6))!;
        expect(day.kwh, 75);
        expect(day.costUgx, closeTo(75 * 800, 1e-6));
        expect(day.firstAt, DateTime(2026, 10, 6, 0, 0, 5));
      });

      test("don't replace a day the app counted more of", () {
        read(100, DateTime(2026, 10, 6, 0, 1));
        read(180, DateTime(2026, 10, 6, 23, 59));
        panelDay('2026-10-06', 20, 180,
            first: DateTime(2026, 10, 6, 18), last: DateTime(2026, 10, 6, 23));
        expect(log.day(DateTime(2026, 10, 6))!.kwh, 80);
      });

      test("today: the app's live readings carry on from the panel's total",
          () {
        // The app opens at 10:00; the panel has counted since midnight.
        panelDay('2026-10-07', 30, 1030,
            first: DateTime(2026, 10, 7, 0, 0, 5),
            last: DateTime(2026, 10, 7, 9, 59));
        read(1031, DateTime(2026, 10, 7, 10)); // live meter reading
        read(1035, DateTime(2026, 10, 7, 11));
        expect(log.day(DateTime(2026, 10, 7))!.kwh, closeTo(35, 1e-9));

        // The panel's next periodic total (counted 1030 → 1036) arrives.
        panelDay('2026-10-07', 36, 1036,
            first: DateTime(2026, 10, 7, 0, 0, 5),
            last: DateTime(2026, 10, 7, 11, 1));
        read(1037, DateTime(2026, 10, 7, 11, 2));
        expect(log.day(DateTime(2026, 10, 7))!.kwh, closeTo(37, 1e-9),
            reason: 'no energy counted twice');
      });
    });

    test('exports CSV, oldest first', () {
      read(100, DateTime(2026, 10, 6, 0, 2));
      read(120, DateTime(2026, 10, 6, 23, 58));
      read(120, DateTime(2026, 10, 7, 8, 30));
      read(130.25, DateTime(2026, 10, 7, 9));

      expect(
        log.toCsv(now: DateTime(2026, 10, 7, 10)),
        'date,kwh,cost_ugx,generator_kwh,generator_cost_ugx,'
        'generator_hours,first_reading,last_reading,complete\n'
        '2026-10-06,20.00,20000,0.00,0,0.00,00:02,23:58,yes\n'
        '2026-10-07,10.25,10250,0.00,0,0.00,08:30,09:00,no\n',
      );
    });

    group('time of use and generator', () {
      // Peak 18-24 at 1000, off-peak 0-6 at 300, shoulder 600; fuel 1750.
      const tou = TimeOfUse(enabled: true, peakRate: 1000, offPeakRate: 300);
      final prices = _TouPrices(tou, standard: 600, generator: 1750);

      void at(double kwh, DateTime t, {bool generator = false}) => log.record(
          registerKwh: kwh, at: t, prices: prices, onGenerator: generator);

      test('grid energy is priced and filed by the hour it was used', () {
        at(100, DateTime(2026, 10, 7, 5));
        at(102, DateTime(2026, 10, 7, 5, 30));
        at(105, DateTime(2026, 10, 7, 12));
        at(106, DateTime(2026, 10, 7, 19));
        final day = log.day(DateTime(2026, 10, 7))!;
        expect(day.costUgx, closeTo(2 * 300 + 3 * 600 + 1 * 1000, 1e-6));
        expect(day.gridHourlyKwh![5], 2);
        expect(day.gridHourlyKwh![12], 3);
        expect(day.gridHourlyKwh![19], 1);
      });

      test('generator energy is counted apart, at fuel cost, with run time',
          () {
        final t = DateTime(2026, 10, 7, 19);
        at(100, t);
        at(104, t.add(const Duration(minutes: 5)), generator: true);
        at(106, t.add(const Duration(minutes: 10)), generator: true);
        // A long gap (app closed) isn't counted as run time.
        at(107, t.add(const Duration(hours: 2)), generator: true);
        final day = log.day(t)!;
        expect(day.generatorKwh, 7);
        expect(day.generatorCostUgx, closeTo(7 * 1750, 1e-6));
        expect(day.generatorSeconds, 600);
        expect(day.gridKwh, 0);
        expect(day.gridHourlyKwh!.every((h) => h == 0), isTrue);
      });

      test('a panel day with hourly figures is priced hour by hour', () {
        log.applyPanelDay(
          date: '2026-10-06',
          kwh: 13,
          registerKwh: 1013,
          firstAt: DateTime(2026, 10, 6, 0, 0, 5),
          lastAt: DateTime(2026, 10, 6, 23, 59, 55),
          gridHourlyKwh: [
            for (var h = 0; h < 24; h++) h == 3 ? 4.0 : (h == 20 ? 5.0 : 0.0)
          ],
          generatorKwh: 4,
          generatorSeconds: 3600,
          prices: prices,
        );
        final day = log.day(DateTime(2026, 10, 6))!;
        expect(day.gridCostUgx, closeTo(4 * 300 + 5 * 1000, 1e-6));
        expect(day.generatorCostUgx, closeTo(4 * 1750, 1e-6));
        expect(day.generatorSeconds, 3600);
      });

      test('the same day arriving again on reconnect is not re-priced', () {
        void deliver(EnergyPrices p) => log.applyPanelDay(
              date: '2026-10-06',
              kwh: 10,
              registerKwh: 1010,
              firstAt: DateTime(2026, 10, 6, 0, 0, 5),
              lastAt: DateTime(2026, 10, 6, 23, 59, 55),
              gridHourlyKwh: List.filled(24, 10 / 24),
              prices: p,
            );
        deliver(const FlatPrices(500));
        deliver(const FlatPrices(900)); // the rate changed since
        expect(log.day(DateTime(2026, 10, 6))!.costUgx, closeTo(5000, 1e-6));
      });

      test('hourly and generator figures survive a JSON round trip', () {
        at(100, DateTime(2026, 10, 7, 9));
        at(103, DateTime(2026, 10, 7, 9, 5), generator: true);
        at(105, DateTime(2026, 10, 7, 10));
        final copy =
            EnergyLog.fromJson(log.toJson()).day(DateTime(2026, 10, 7))!;
        expect(copy.gridHourlyKwh![10], 2);
        expect(copy.generatorKwh, 3);
        expect(copy.generatorSeconds, 300);
      });
    });
  });

  group('PowerMonitor history', () {
    late StreamController<PanelTelemetry> telemetry;
    late DateTime now;

    setUp(() {
      telemetry = StreamController<PanelTelemetry>.broadcast(sync: true);
      now = DateTime(2026, 10, 7, 9);
    });
    tearDown(() => telemetry.close());

    Future<PowerMonitor> create() async {
      final m = PowerMonitor(telemetry.stream,
          clock: () => now, prices: const FlatPrices(900));
      await m.init();
      return m;
    }

    void meter(double kwh) => telemetry.add(MeterReport(watts: 0, kwh: kwh));

    test('keeps past days across a restart, with cost', () async {
      SharedPreferences.setMockInitialValues({});
      var monitor = await create();
      meter(100);
      now = now.add(const Duration(hours: 8));
      meter(130);
      now = DateTime(2026, 10, 8, 7);
      meter(131); // new day: saved straight away
      await Future<void>.delayed(Duration.zero);
      monitor.dispose();

      monitor = await create();
      final day = monitor.history.day(DateTime(2026, 10, 7))!;
      expect(day.kwh, closeTo(30, 1e-9));
      expect(day.costUgx, closeTo(27000, 1e-6));
      monitor.dispose();
    });

    test('takes day totals from the panel and saves them', () async {
      SharedPreferences.setMockInitialValues({});
      var monitor = await create();
      telemetry.add(EnergyDayReport(
        date: '2026-10-06',
        kwh: 80,
        registerKwh: 1080,
        firstAt: DateTime(2026, 10, 6, 0, 0, 5),
        lastAt: DateTime(2026, 10, 6, 23, 59, 55),
      ));
      expect(monitor.history.day(DateTime(2026, 10, 6))!.costUgx, 72000);
      monitor.dispose(); // saves what the debounce hadn't yet
      await Future<void>.delayed(Duration.zero);

      monitor = await create();
      expect(monitor.history.day(DateTime(2026, 10, 6))!.kwh, 80);
      monitor.dispose();
    });

    test("carries over today's start from the older storage format", () async {
      SharedPreferences.setMockInitialValues({
        'meter_day': '2026-10-07',
        'meter_day_start_kwh': 48210.0,
        'meter_day_start_at': DateTime(2026, 10, 7, 6).toIso8601String(),
      });
      final monitor = await create();
      meter(48222);
      expect(monitor.energyTodayKwh, closeTo(12, 1e-9));
      expect(monitor.energyTodaySince, DateTime(2026, 10, 7, 6));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('meter_day_start_kwh'), isFalse);
      monitor.dispose();
    });
  });
}

class _TouPrices implements EnergyPrices {
  _TouPrices(this.tou, {required this.standard, required this.generator});

  final TimeOfUse tou;
  final double standard;
  final double generator;

  @override
  double gridRateAt(DateTime time) => tou.rateFor(tou.bandAt(time), standard);

  @override
  double get generatorRatePerKwh => generator;
}
