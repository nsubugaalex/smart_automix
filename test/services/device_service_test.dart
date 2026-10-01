import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_automix/constants/uedcl_tariffs.dart';
import 'package:smart_automix/models/device_model.dart';
import 'package:smart_automix/services/device_service.dart';
import 'package:smart_automix/services/tariff_service.dart';

final _machines = [
  DeviceModel(
    id: 'a',
    name: 'Compressor',
    type: 'compressor',
    location: 'Bay 1',
    isOn: true,
    powerConsumption: 2000,
    powerFactor: 0.8,
    hoursPerDay: 5,
  ),
  DeviceModel(
    id: 'b',
    name: 'Mill',
    type: 'mill',
    location: 'Mill',
    isOn: false,
    powerConsumption: 7500,
    phase: 'three',
    voltage: 415,
    powerFactor: 0.75,
    hoursPerDay: 2,
  ),
];

Future<(DeviceService, TariffService)> _load() async {
  SharedPreferences.setMockInitialValues({
    'devices': jsonEncode(_machines.map((m) => m.toJson()).toList()),
  });
  final tariff = TariffService();
  await tariff.init();
  await tariff.confirmTariff(
    category: UedclTariffCategory.smallIndustrial,
    ratePerKwh: 500,
    monthlyFixedCharge: 9000,
  );
  final devices = DeviceService(tariff);
  await devices.init();
  return (devices, tariff);
}

void main() {
  test('loads demo machines when nothing is stored', () async {
    SharedPreferences.setMockInitialValues({});
    final devices = DeviceService(TariffService());
    await devices.init();
    expect(devices.devices, isNotEmpty);
  });

  test('live load counts only running machines', () async {
    final (devices, _) = await _load();

    expect(devices.totalPowerConsumption, 2000);
    expect(devices.totalApparentPowerKva, closeTo(2.5, 1e-9));
  });

  test('daily energy and cost follow schedules, not current on/off state', () async {
    final (devices, _) = await _load();

    // 2 kW x 5 h + 7.5 kW x 2 h = 25 kWh, even though the mill is off.
    expect(devices.totalDailyEnergyKWh, closeTo(25, 1e-9));
    expect(devices.totalEstimatedDailyCostUgx, closeTo(25 * 500, 1e-6));
    expect(
      devices.totalEstimatedMonthlyCostUgx,
      closeTo(25 * TariffService.daysPerMonth * 500 + 9000, 1e-6),
    );

    await devices.turnOffAllDevices();
    expect(devices.totalDailyEnergyKWh, closeTo(25, 1e-9));
  });

  test('costs follow the injected tariff when it changes', () async {
    final (devices, tariff) = await _load();
    await tariff.confirmTariff(
      category: UedclTariffCategory.commercial,
      ratePerKwh: 1000,
      monthlyFixedCharge: 0,
    );
    expect(devices.totalEstimatedDailyCostUgx, closeTo(25 * 1000, 1e-6));
  });

  test('toggle and bulk switching update state', () async {
    final (devices, _) = await _load();

    await devices.toggleDevice('b');
    expect(devices.getDeviceById('b')!.isOn, isTrue);
    expect(devices.getActiveDevices(), hasLength(2));

    await devices.turnOffAllDevices();
    expect(devices.getActiveDevices(), isEmpty);
    expect(devices.totalApparentPowerKva, 0);

    await devices.turnOnAllDevices();
    expect(devices.getActiveDevices(), hasLength(2));
  });
}
