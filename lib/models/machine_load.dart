import 'package:flutter/foundation.dart';

import '../services/power_monitor.dart';
import 'device_model.dart';

/// What a machine is drawing: measured by the panel's sensors when a
/// recent reading exists, otherwise estimated from its nameplate ratings.
@immutable
class MachineLoad {
  const MachineLoad._({
    required this.watts,
    required this.amps,
    required this.kva,
    required this.isMeasured,
    required this.exceedsBreaker,
  });

  /// Nameplate estimate: rated draw while on, nothing while off.
  factory MachineLoad.estimated(DeviceModel device) => MachineLoad._(
        watts: device.isOn ? device.powerConsumption : 0,
        amps: device.currentDrawAmps,
        kva: device.currentApparentPowerKva,
        isMeasured: false,
        exceedsBreaker: device.isOn && device.isOverloaded,
      );

  factory MachineLoad.measured(DeviceModel device, PowerReading reading) {
    final breaker = device.breakerRatingAmps;
    return MachineLoad._(
      watts: reading.watts,
      amps: reading.amps,
      kva: device.apparentPowerKvaAt(reading.amps),
      isMeasured: true,
      exceedsBreaker: breaker != null && reading.amps > breaker,
    );
  }

  final double watts;

  /// Line current (per phase on a three-phase machine).
  final double amps;
  final double kva;
  final bool isMeasured;

  /// Drawing more current than the machine's breaker allows: measured, or
  /// (for an estimate) its rated current when running.
  final bool exceedsBreaker;
}
