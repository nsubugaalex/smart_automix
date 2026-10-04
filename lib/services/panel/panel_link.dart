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
