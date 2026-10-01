import 'package:flutter_test/flutter_test.dart';
import 'package:smart_automix/models/device_model.dart';

DeviceModel machine({
  bool isOn = true,
  double watts = 2300,
  String phase = 'single',
  double voltage = 230,
  double powerFactor = 1.0,
  double? breaker,
  double hoursPerDay = 4,
}) {
  return DeviceModel(
    id: 'm1',
    name: 'Test machine',
    type: 'motor',
    location: 'Bay 1',
    isOn: isOn,
    powerConsumption: watts,
    phase: phase,
    voltage: voltage,
    powerFactor: powerFactor,
    breakerRatingAmps: breaker,
    hoursPerDay: hoursPerDay,
  );
}

void main() {
  group('ratedCurrentAmps', () {
    test('single-phase is P / (V x pf)', () {
      expect(machine(watts: 2300, voltage: 230, powerFactor: 1).ratedCurrentAmps,
          closeTo(10, 1e-9));
      expect(machine(watts: 2300, voltage: 230, powerFactor: 0.5).ratedCurrentAmps,
          closeTo(20, 1e-9));
    });

    test('three-phase is P / (sqrt3 x V x pf)', () {
      final m = machine(watts: 7500, phase: 'three', voltage: 415, powerFactor: 0.85);
      expect(m.ratedCurrentAmps, closeTo(7500 / (1.732 * 415 * 0.85), 1e-9));
    });

    test('is 0 for missing specs instead of dividing by zero', () {
      expect(machine(voltage: 0).ratedCurrentAmps, 0);
      expect(machine(powerFactor: 0).ratedCurrentAmps, 0);
      expect(machine(watts: 0).ratedCurrentAmps, 0);
    });

    test('live current draw is 0 when switched off', () {
      expect(machine(isOn: false).currentDrawAmps, 0);
      expect(machine(isOn: true).currentDrawAmps, closeTo(10, 1e-9));
    });
  });

  group('isOverloaded', () {
    test('compares rated current to the breaker rating', () {
      expect(machine(breaker: 16).isOverloaded, isFalse); // 10 A on 16 A
      expect(machine(breaker: 6).isOverloaded, isTrue); // 10 A on 6 A
    });

    test('is false when no breaker rating is known', () {
      expect(machine(breaker: null).isOverloaded, isFalse);
    });
  });

  group('apparentPowerKva', () {
    test('is P / pf in kVA, and 0 live when off', () {
      final m = machine(watts: 1700, powerFactor: 0.85);
      expect(m.apparentPowerKva, closeTo(2.0, 1e-9));
      expect(m.currentApparentPowerKva, closeTo(2.0, 1e-9));
      expect(m.copyWith(isOn: false).currentApparentPowerKva, 0);
    });
  });

  group('dailyEnergyKWh', () {
    test('is rated power x scheduled hours', () {
      expect(machine(watts: 1500, hoursPerDay: 4).dailyEnergyKWh(), closeTo(6, 1e-9));
    });

    test('does not depend on the current on/off state', () {
      final m = machine(watts: 1500, hoursPerDay: 4);
      expect(m.copyWith(isOn: false).dailyEnergyKWh(), m.dailyEnergyKWh());
    });

    test('can be overridden with hypothetical hours', () {
      expect(machine(watts: 1000).dailyEnergyKWh(hoursPerDay: 10), closeTo(10, 1e-9));
    });
  });

  test('survives a JSON round trip', () {
    final original = machine(phase: 'three', voltage: 415, breaker: 25);
    final copy = DeviceModel.fromJson(original.toJson());
    expect(copy.toJson(), original.toJson());
  });
}
