import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_automix/services/energy_log.dart';
import 'package:smart_automix/services/panel/panel_link.dart';
import 'package:smart_automix/services/power_monitor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EnergyLog', () {
    late EnergyLog log;
    setUp(() => log = EnergyLog());

    void read(double kwh, DateTime at, {double rate = 1000}) =>
        log.record(registerKwh: kwh, at: at, ratePerKwh: rate);

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
              ratePerKwh: 1000);

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
        'date,kwh,cost_ugx,first_reading,last_reading,complete\n'
        '2026-10-06,20.00,20000,00:02,23:58,yes\n'
        '2026-10-07,10.25,10250,08:30,09:00,no\n',
      );
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
          clock: () => now, ratePerKwh: () => 900);
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
