import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_automix/constants/uedcl_tariffs.dart';
import 'package:smart_automix/models/device_model.dart';
import 'package:smart_automix/services/alert_service.dart';
import 'package:smart_automix/services/device_service.dart';
import 'package:smart_automix/services/tariff_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TariffService tariff;
  late DeviceService devices;
  late AlertService alerts;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'devices': jsonEncode([
        DeviceModel(
          id: 'a',
          name: 'Cold room',
          type: 'coldroom',
          location: 'Cold room',
          powerConsumption: 1000,
          hoursPerDay: 10,
        ).toJson(),
      ]),
    });
    tariff = TariffService();
    await tariff.init();
    devices = DeviceService(tariff);
    await devices.init();
    alerts = AlertService(devices, tariff);
  });

  Iterable<String> ids() => alerts.alerts.map((a) => a.id);

  test('an unconfirmed tariff raises one stale alert, not duplicates', () async {
    await alerts.checkTariffHealth();
    await alerts.checkTariffHealth();

    expect(ids().where((id) => id == 'tariff-stale'), hasLength(1));
    expect(alerts.unreadCount, 1);
  });

  test('confirming the tariff resolves the stale alert', () async {
    await alerts.checkTariffHealth();
    await tariff.confirmTariff(
      category: UedclTariffCategory.smallIndustrial,
      ratePerKwh: 500,
      monthlyFixedCharge: 0,
    );
    await alerts.checkTariffHealth();

    expect(ids(), isNot(contains('tariff-stale')));
  });

  test('cost threshold alert is raised above the limit and cleared below it', () async {
    // 1 kW x 10 h = 10 kWh/day x 500 = 5,000 UGX/day.
    await tariff.confirmTariff(
      category: UedclTariffCategory.smallIndustrial,
      ratePerKwh: 500,
      monthlyFixedCharge: 0,
      dailyCostAlertThreshold: 4000,
    );
    await alerts.checkTariffHealth();
    expect(ids(), contains('tariff-cost-threshold'));

    await tariff.confirmTariff(
      category: UedclTariffCategory.smallIndustrial,
      ratePerKwh: 500,
      monthlyFixedCharge: 0,
      dailyCostAlertThreshold: 6000,
    );
    await alerts.checkTariffHealth();
    expect(ids(), isNot(contains('tariff-cost-threshold')));
  });

  test('alerts persist and can be marked read and dismissed', () async {
    await alerts.add(title: 'Hello', message: 'World');
    final id = alerts.alerts.single.id;

    await alerts.markRead(id);
    expect(alerts.unreadCount, 0);

    final reloaded = AlertService(devices, tariff);
    await reloaded.init();
    expect(reloaded.alerts.map((a) => a.title), contains('Hello'));

    await alerts.dismiss(id);
    expect(alerts.alerts, isEmpty);
  });
}
