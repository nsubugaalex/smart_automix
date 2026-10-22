import 'dart:async';

import 'package:flutter/foundation.dart';

/// How the app is currently linked to the switch-panel hardware.
enum PanelLinkStatus {
  /// No hardware: commands are applied locally (demo / development mode).
  simulated,

  /// Connecting — or reconnecting after a dropped connection.
  connecting,

  /// Connected to the broker. [PanelLink.panelOnline] says whether the
  /// panel controller itself is reachable.
  connected,

  /// Not connected; commands cannot be delivered.
  disconnected,
}

/// A machine's on/off state as reported by the switch panel.
@immutable
class MachineStateReport {
  const MachineStateReport(this.machineId, {required this.isOn});

  final String machineId;
  final bool isOn;
}

/// A measurement sent by the panel's sensors.
sealed class PanelTelemetry {
  const PanelTelemetry();
}

/// What one machine is drawing right now. [amps] is the line current
/// (per phase on a three-phase machine).
@immutable
class MachinePowerReport extends PanelTelemetry {
  const MachinePowerReport(this.machineId,
      {required this.watts, required this.amps});

  final String machineId;
  final double watts;
  final double amps;
}

/// The panel's supply meter: total real power through the main incomer,
/// and the meter's cumulative energy register.
@immutable
class MeterReport extends PanelTelemetry {
  const MeterReport({required this.watts, required this.kwh});

  final double watts;
  final double kwh;
}

/// One day's energy through the supply meter, as totalled by the panel.
/// The panel is always on, so this covers time the app was closed.
@immutable
class EnergyDayReport extends PanelTelemetry {
  const EnergyDayReport({
    required this.date,
    required this.kwh,
    required this.registerKwh,
    required this.firstAt,
    required this.lastAt,
  });

  /// Local calendar date, `YYYY-MM-DD`.
  final String date;
  final double kwh;

  /// The meter register at [lastAt].
  final double registerKwh;
  final DateTime firstAt;
  final DateTime lastAt;
}

/// The connection between the app and the switch panel.
///
/// Commands go out through [sendCommand]; the resulting machine state comes
/// back on [stateReports]. The app only shows a machine as switched once
/// the panel has reported it, so the screen never claims a machine is off
/// when the command didn't actually reach the hardware.
abstract class PanelLink extends ChangeNotifier {
  PanelLinkStatus get status;

  /// Whether the panel controller reports itself online (null if unknown).
  bool? get panelOnline;

  /// Why the last connection attempt failed, if it did.
  String? get lastError;

  Stream<MachineStateReport> get stateReports;

  /// Power and energy readings, if the panel has sensors fitted.
  Stream<PanelTelemetry> get telemetry;

  bool get canSendCommands =>
      status == PanelLinkStatus.simulated ||
      status == PanelLinkStatus.connected;

  Future<void> connect();

  /// Ask the panel to switch [machineId] on or off. Returns false if the
  /// command could not be sent (e.g. not connected).
  Future<bool> sendCommand(String machineId, {required bool on});
}

/// Stand-in for real hardware: every command is confirmed immediately.
class SimulatedPanelLink extends PanelLink {
  // Synchronous so a simulated switch takes effect before sendCommand
  // returns, exactly like the app behaved before hardware support.
  final _reports = StreamController<MachineStateReport>.broadcast(sync: true);

  @override
  PanelLinkStatus get status => PanelLinkStatus.simulated;

  @override
  bool? get panelOnline => true;

  @override
  String? get lastError => null;

  @override
  Stream<MachineStateReport> get stateReports => _reports.stream;

  /// No sensors in simulation: the app falls back to nameplate estimates.
  @override
  Stream<PanelTelemetry> get telemetry => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<bool> sendCommand(String machineId, {required bool on}) async {
    _reports.add(MachineStateReport(machineId, isOn: on));
    return true;
  }

  @override
  void dispose() {
    _reports.close();
    super.dispose();
  }
}
