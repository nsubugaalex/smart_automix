import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_automix/models/device_model.dart';
import 'package:smart_automix/screens/prepaid/prepaid_screen.dart';
import 'package:smart_automix/services/alert_service.dart';
import 'package:smart_automix/services/device_service.dart';
import 'package:smart_automix/services/prepaid_service.dart';
import 'package:smart_automix/services/tariff_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PrepaidService', () {
    late DateTime now;
    late DeviceService devices;
    late PrepaidService prepaid;

    setUp(() async {
      now = DateTime(2026, 10, 23, 8);
      // One machine estimated at 2.2 kW x 10 h = 22 kWh a day, no meter.
      SharedPreferences.setMockInitialValues({
        'devices': jsonEncode([
          DeviceModel(
                  id: 'mill',
                  name: 'Mill',
                  type: 'mill',
                  location: 'A',
                  powerConsumption: 2200,
                  hoursPerDay: 10)
              .toJson(),
        ]),
      });
      devices = DeviceService(TariffService());
      await devices.init();
      prepaid = PrepaidService(devices: devices, clock: () => now);
      await prepaid.init();
    });

    tearDown(() => prepaid.dispose());

    test('a purchase with the meter balance after it starts tracking',
        () async {
      await prepaid.configure(enabled: true, meterNumber: '0412 3456 789');
      expect(prepaid.meterNumber, '04123456789');
      expect(prepaid.balance, isNull);

      await prepaid.addPurchase(
          units: 200, amountUgx: 150000, meterShowsAfter: 230);
      now = now.add(const Duration(days: 1));
      final b = prepaid.balance!;
      expect(b.measured, isFalse);
      expect(b.units, closeTo(230 - 22, 0.1));
      expect(prepaid.averagePrice, 750);
      expect(prepaid.isLow, isFalse);
    });

    test('low credit raises one alert, cleared by a token', () async {
      await prepaid.configure(enabled: true, warnDays: 3);
      await prepaid.addReading(50); // ~2.3 days at 22 kWh/day
      final alerts = AlertService(devices, TariffService(), prepaid: prepaid);
      await alerts.checkPrepaid();
      expect(prepaid.isLow, isTrue);
      expect(alerts.alerts.single.title, 'Yaka credit running low');

      await prepaid.addPurchase(units: 300);
      await alerts.checkPrepaid();
      expect(alerts.alerts, isEmpty);
    });

    test('kept across a restart', () async {
      await prepaid.configure(enabled: true);
      await prepaid.addReading(80);
      final again = PrepaidService(devices: devices, clock: () => now);
      await again.init();
      expect(again.enabled, isTrue);
      expect(again.balance!.units, closeTo(80, 1e-6));
      again.dispose();
    });
  });

  testWidgets('screen: switch on, read the meter, add a token', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await deviceService.init();
    await prepaidService.init();
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    await tester.pumpWidget(const MaterialApp(home: PrepaidScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('This site has a prepaid Yaka meter'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter the units left'), findsOneWidget);

    await tester.tap(find.text('Enter meter reading'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '120');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('120 kWh'), findsOneWidget);

    await tester.tap(find.text('I bought a token'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '200');
    await tester.enterText(find.byType(TextField).at(1), '150,000');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('320 kWh'), findsOneWidget);
    expect(find.textContaining('Token: +200 kWh for UGX'), findsOneWidget);
    expect(find.textContaining('per unit on average'), findsOneWidget);

    // Deleting can be undone.
    await tester.tap(find.byTooltip('Delete').first);
    await tester.pumpAndSettle();
    expect(find.text('120 kWh'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('320 kWh'), findsOneWidget);
  });
}
