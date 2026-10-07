import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_automix/services/panel/panel_link.dart';
import 'package:smart_automix/services/power_monitor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<PanelTelemetry> telemetry;
  late DateTime now;
  late PowerMonitor monitor;

  Future<PowerMonitor> createMonitor() async {
    final m = PowerMonitor(telemetry.stream, clock: () => now);
    await m.init();
    return m;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    telemetry = StreamController<PanelTelemetry>.broadcast(sync: true);
    now = DateTime(2026, 10, 7, 9);
    monitor = await createMonitor();
  });

  tearDown(() {
    monitor.dispose();
    telemetry.close();
  });

  void meter(double kwh, {double watts = 5000}) =>
      telemetry.add(MeterReport(watts: watts, kwh: kwh));

  test('keeps the latest machine reading while it is recent', () {
    telemetry
      ..add(const MachinePowerReport('4', watts: 6000, amps: 10))
      ..add(const MachinePowerReport('4', watts: 6500, amps: 11));

    expect(monitor.machine('4')?.watts, 6500);
    expect(monitor.machine('5'), isNull);
    expect(monitor.hasReadings, isTrue);
  });

  test('readings older than maxAge are ignored and then removed', () {
    var notified = 0;
    monitor.addListener(() => notified++);
    telemetry.add(const MachinePowerReport('4', watts: 6000, amps: 10));
    meter(100);
    notified = 0;

    now = now.add(PowerMonitor.defaultMaxAge + const Duration(seconds: 1));
    expect(monitor.machine('4'), isNull);
    expect(monitor.meter, isNull);
    expect(monitor.hasReadings, isFalse);

    monitor.removeStale();
    expect(notified, 1, reason: 'screens must refresh to show estimates');
  });

  test("today's energy is the meter's increase since the day's first reading",
      () {
    meter(48210);
    now = now.add(const Duration(hours: 3));
    meter(48235.5);

    expect(monitor.energyTodayKwh, closeTo(25.5, 1e-9));
    expect(monitor.energyTodaySince, DateTime(2026, 10, 7, 9));
  });

  test('a new day starts counting again from zero', () {
    meter(48210);
    now = DateTime(2026, 10, 8, 0, 1);
    meter(48300);

    expect(monitor.energyTodayKwh, 0);
    now = now.add(const Duration(hours: 1));
    meter(48304);
    expect(monitor.energyTodayKwh, closeTo(4, 1e-9));
  });

  test('a register that goes backwards (meter replaced) restarts the count',
      () {
    meter(48210);
    meter(12);
    meter(15);

    expect(monitor.energyTodayKwh, closeTo(3, 1e-9));
  });

  test("the day's starting reading survives an app restart", () async {
    meter(48210);
    await Future<void>.delayed(Duration.zero); // let it save
    monitor.dispose();

    now = now.add(const Duration(hours: 2));
    monitor = await createMonitor();
    expect(monitor.energyTodayKwh, isNull, reason: 'no reading yet');
    meter(48222);
    expect(monitor.energyTodayKwh, closeTo(12, 1e-9));
  });
}
