import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/device_model.dart';
import '../models/machine_load.dart';
import '../models/supply.dart';
import '../utils/debouncer.dart';
import 'energy_log.dart';
import 'panel/panel_link.dart';
import 'panel_service.dart';
import 'power_monitor.dart';
import 'tariff_service.dart';

/// A switch command that didn't take effect.
@immutable

/// A machine's confirmed switch, for the activity log.
class MachineChange {
  const MachineChange(this.device,
      {required this.isOn, required this.requestedHere});

  final DeviceModel device;
  final bool isOn;

  /// Whether this app sent the command that caused it.
  final bool requestedHere;
}

class CommandFailure {
  const CommandFailure(this.machineName, this.reason);

  final String machineName;
  final String reason;
}

/// How the load figures on screen were obtained.
enum LoadSource {
  /// From the supply meter, or every machine's sensor.
  measured,

  /// Some machines measured, the rest estimated from nameplate ratings.
  partlyMeasured,

  /// No sensor readings: estimated from nameplate ratings.
  estimated,
}

/// Service for managing the machines/circuits wired to the industrial
/// switch panel: their on/off state, load, and remote control.
///
/// On/off commands go to the panel through [PanelService]; a machine's
/// state only changes when the panel reports it, so the screen reflects
/// what the hardware actually did. Load figures use the panel's power
/// readings ([PowerMonitor]) where available and nameplate estimates
/// otherwise.
class DeviceService extends ChangeNotifier {
  DeviceService(
    this._tariff, {
    PanelService? panel,
    PowerMonitor? power,
    this.confirmTimeout = defaultConfirmTimeout,
  })  : _panel = panel ?? PanelService(),
        _ownsPower = power == null {
    _power = power ?? PowerMonitor(_panel.telemetry, prices: _tariff);
    _power.addListener(notifyListeners);
    _reportsSub = _panel.stateReports.listen(_onStateReport);
  }

  final TariffService _tariff;
  final PanelService _panel;
  late final PowerMonitor _power;
  final bool _ownsPower;
  late final StreamSubscription<MachineStateReport> _reportsSub;
  final List<DeviceModel> _devices = [];
  bool _isLoading = false;
  String? _error;

  // Coalesces rapid mutations (e.g. flipping several switches at once)
  // into a single SharedPreferences write instead of one write per change.
  final Debouncer _saveDebouncer =
      Debouncer(delay: const Duration(milliseconds: 400));

  /// Gap between machines during [startAllStaggered], so motor inrush
  /// currents don't stack up and trip the main supply breaker.
  static const startStagger = Duration(seconds: 5);

  // Incremented to cancel an in-progress staggered start.
  int _startSequenceId = 0;
  int _pendingStarts = 0;

  /// How long to wait for the panel to confirm a command.
  static const defaultConfirmTimeout = Duration(seconds: 5);
  final Duration confirmTimeout;

  // Machines with a command sent but not yet confirmed by the panel.
  final Set<String> _awaitingConfirmation = {};
  final Map<String, Timer> _confirmTimers = {};
  final _failures = StreamController<CommandFailure>.broadcast();
  final _changes = StreamController<MachineChange>.broadcast();

  // Getters
  List<DeviceModel> get devices => List.unmodifiable(_devices);
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Machines still waiting to be switched on by [startAllStaggered]
  /// (0 when no start sequence is running).
  int get pendingStarts => _pendingStarts;
  bool get isStartSequenceRunning => _pendingStarts > 0;

  /// Whether a command for [deviceId] is waiting for panel confirmation.
  bool isAwaitingConfirmation(String deviceId) =>
      _awaitingConfirmation.contains(deviceId);

  /// Commands the panel refused, couldn't receive, or never confirmed.
  Stream<CommandFailure> get commandFailures => _failures.stream;

  /// Every confirmed change in a machine's state, and whether this app
  /// asked for it, for the activity log.
  Stream<MachineChange> get machineChanges => _changes.stream;

  /// Get devices filtered by location
  List<DeviceModel> getDevicesByLocation(String location) {
    return _devices.where((d) => d.location == location).toList();
  }

  /// Get devices filtered by type
  List<DeviceModel> getDevicesByType(String type) {
    return _devices.where((d) => d.type == type).toList();
  }

  /// Get all active (on) devices
  List<DeviceModel> getActiveDevices() {
    return _devices.where((d) => d.isOn).toList();
  }

  /// What [device] is drawing: measured if the panel has a recent
  /// reading for it, otherwise estimated from its ratings.
  MachineLoad loadOf(DeviceModel device) {
    final reading = _power.machine(device.id);
    return reading == null
        ? MachineLoad.estimated(device)
        : MachineLoad.measured(device, reading);
  }

  /// Total real power (W) being drawn right now: the supply meter's reading
  /// if there is one (it also covers loads the app doesn't control),
  /// otherwise the sum over all machines.
  double get totalPowerConsumption {
    return _power.meter?.watts ??
        _devices.fold(0.0, (sum, d) => sum + loadOf(d).watts);
  }

  /// Total apparent power (kVA) being drawn right now across all running
  /// machines. Used instead of summing amps, which isn't meaningful across
  /// a mix of 230V single-phase and 415V three-phase machines.
  double get totalApparentPowerKva {
    return _devices.fold(0.0, (sum, d) => sum + loadOf(d).kva);
  }

  /// Whether [totalPowerConsumption] and the per-machine figures are
  /// measured or estimated.
  LoadSource get loadSource {
    if (_devices.isNotEmpty &&
        _devices.every((d) => _power.machine(d.id) != null)) {
      return LoadSource.measured;
    }
    return _power.hasReadings
        ? LoadSource.partlyMeasured
        : LoadSource.estimated;
  }

  /// Energy through the supply meter today (kWh), or null without a meter.
  double? get meteredEnergyTodayKwh => _power.energyTodayKwh;

  /// When [meteredEnergyTodayKwh] started counting (midnight, or when the
  /// app first saw the meter today).
  DateTime? get meteredEnergyTodaySince => _power.energyTodaySince;

  /// Metered energy and cost per day, from the supply meter.
  EnergyLog get energyHistory => _power.history;

  /// Whether the panel is on generator power; null if it doesn't report
  /// its supply source.
  bool? get onGenerator => _power.onGenerator;

  /// The panel's supply protection state; null if it doesn't report one.
  SupplyState? get supplyState => _power.supplyState;
  DateTime? get supplySince => _power.supplySince;

  /// Incomer phase voltages from a recent meter reading, or null.
  List<double?>? get supplyVolts => _power.meter?.volts;

  /// Supply faults and power cuts, newest first.
  List<SupplyEvent> get supplyEvents => _power.supplyEvents;
  Stream<SupplyEventChange> get supplyEventChanges => _power.supplyEventChanges;

  /// Whether machines may be started: false while the panel reports a
  /// supply fault or is waiting for the supply to settle.
  bool get supplyAllowsStart => _supplyAllows(_power.supplyState);

  static bool _supplyAllows(SupplyState? state) =>
      state == null || state.allowsStart;

  /// Cost of [meteredEnergyTodayKwh] at the current tariff, in UGX.
  double? get meteredCostTodayUgx {
    final kwh = meteredEnergyTodayKwh;
    return kwh == null ? null : _tariff.costFor(kwh);
  }

  /// Machines whose rated current exceeds their protective breaker, or
  /// that the panel measures drawing more than it.
  List<DeviceModel> getOverloadedDevices() {
    return _devices
        .where((d) => d.isOverloaded || loadOf(d).exceedsBreaker)
        .toList();
  }

  /// Machines the panel measures drawing more current than their breaker
  /// allows right now.
  List<DeviceModel> getMeasuredOvercurrentDevices() {
    return _devices.where((d) {
      final load = loadOf(d);
      return load.isMeasured && load.exceedsBreaker;
    }).toList();
  }

  /// Get device by ID
  DeviceModel? getDeviceById(String id) {
    try {
      return _devices.firstWhere((d) => d.id == id);
    } catch (e) {
      return null;
    }
  }

  /// Initialize device service and load devices from storage
  Future<void> init() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await _power.init();
      await _loadDevices();
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _isLoading = false;
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  /// Load devices from local storage
  Future<void> _loadDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final devicesJson = prefs.getString('devices');

    if (devicesJson != null) {
      final decoded = jsonDecode(devicesJson) as List<dynamic>;
      _devices.clear();
      _devices.addAll(
        decoded
            .map((d) => DeviceModel.fromJson(d as Map<String, dynamic>))
            .toList(),
      );
    } else {
      // Load default devices for demo
      _loadDefaultDevices();
    }
  }

  /// Load default machines for demonstration (typical small workshop loads,
  /// with realistic electrical nameplate specs for current/overload checks)
  void _loadDefaultDevices() {
    _devices.clear();
    _devices.addAll([
      DeviceModel(
        id: '1',
        name: 'Grinding Machine',
        type: 'grinder',
        location: 'Workshop Bay 1',
        isOn: true,
        powerConsumption: 750.0,
        voltage: 230,
        breakerRatingAmps: 10,
        hoursPerDay: 3,
        lastUsed: DateTime.now(),
      ),
      DeviceModel(
        id: '2',
        name: 'Air Compressor',
        type: 'compressor',
        location: 'Workshop Bay 1',
        isOn: true,
        powerConsumption: 2200.0,
        voltage: 230,
        breakerRatingAmps: 16,
        hoursPerDay: 6,
        lastUsed: DateTime.now(),
      ),
      DeviceModel(
        id: '3',
        name: 'Welding Machine',
        type: 'welder',
        location: 'Workshop Bay 2',
        isOn: false,
        powerConsumption: 5500.0,
        phase: 'three',
        voltage: 415,
        breakerRatingAmps: 16,
        hoursPerDay: 2,
        lastUsed: DateTime.now().subtract(const Duration(hours: 2)),
      ),
      DeviceModel(
        id: '4',
        name: 'Maize Mill Motor',
        type: 'mill',
        location: 'Milling Section',
        isOn: true,
        powerConsumption: 7500.0,
        phase: 'three',
        voltage: 415,
        breakerRatingAmps: 25,
        hoursPerDay: 8,
        lastUsed: DateTime.now(),
      ),
      DeviceModel(
        id: '5',
        name: 'Borehole Pump',
        type: 'pump',
        location: 'Pump House',
        isOn: false,
        powerConsumption: 1100.0,
        voltage: 230,
        breakerRatingAmps: 10,
        hoursPerDay: 3,
        lastUsed: DateTime.now().subtract(const Duration(days: 1)),
      ),
      DeviceModel(
        id: '6',
        name: 'Cold Room Unit',
        type: 'coldroom',
        location: 'Cold Room',
        isOn: true,
        powerConsumption: 1800.0,
        voltage: 230,
        breakerRatingAmps: 16,
        hoursPerDay: 10,
        lastUsed: DateTime.now(),
      ),
    ]);
  }

  /// Save devices to local storage
  Future<void> _saveDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final devicesJson = jsonEncode(_devices.map((d) => d.toJson()).toList());
    await prefs.setString('devices', devicesJson);
  }

  /// Schedule a debounced save — coalesces rapid successive mutations
  /// (e.g. several switch taps in quick succession) into one disk write.
  void _scheduleSave() {
    _saveDebouncer.call(() {
      _saveDevices();
    });
  }

  /// Add a new device
  Future<void> addDevice(DeviceModel device) async {
    _devices.add(device);
    _scheduleSave();
    notifyListeners();
  }

  /// Update an existing device
  Future<void> updateDevice(DeviceModel updatedDevice) async {
    final index = _devices.indexWhere((d) => d.id == updatedDevice.id);
    if (index != -1) {
      _devices[index] = updatedDevice;
      _scheduleSave();
      notifyListeners();
    }
  }

  /// Remove a device
  Future<void> removeDevice(String deviceId) async {
    _devices.removeWhere((d) => d.id == deviceId);
    _scheduleSave();
    notifyListeners();
  }

  /// Toggle device power state
  Future<void> toggleDevice(String deviceId) async {
    final device = getDeviceById(deviceId);
    if (device != null) await _command(device, on: !device.isOn);
  }

  /// Turn on a device
  Future<void> turnOnDevice(String deviceId) async {
    final device = getDeviceById(deviceId);
    if (device != null) await _command(device, on: true);
  }

  /// Turn off a device
  Future<void> turnOffDevice(String deviceId) async {
    final device = getDeviceById(deviceId);
    if (device != null) await _command(device, on: false);
  }

  /// Send an on/off command to the panel. The device's state changes in
  /// [_onStateReport] once the panel confirms it — immediately in
  /// simulation, or when the hardware reports back over MQTT.
  Future<void> _command(DeviceModel device, {required bool on}) async {
    final id = device.id;
    if (device.isOn == on || _awaitingConfirmation.contains(id)) return;

    _awaitingConfirmation.add(id);
    notifyListeners();

    final sent = await _panel.sendCommand(id, on: on);
    if (!_awaitingConfirmation.contains(id)) return; // already confirmed

    if (!sent) {
      _clearAwaiting(id);
      _failures.add(
          CommandFailure(device.name, 'Not connected to the switch panel.'));
      return;
    }
    _confirmTimers[id] = Timer(confirmTimeout, () {
      if (!_awaitingConfirmation.contains(id)) return;
      _clearAwaiting(id);
      _failures.add(CommandFailure(
        device.name,
        'The switch panel did not confirm the command within '
        '${confirmTimeout.inSeconds}s. Check the machine on site, and '
        "that this device's clock is correct.",
      ));
    });
  }

  void _clearAwaiting(String id) {
    _awaitingConfirmation.remove(id);
    _confirmTimers.remove(id)?.cancel();
    notifyListeners();
  }

  void _onStateReport(MachineStateReport report) {
    final index = _devices.indexWhere((d) => d.id == report.machineId);
    if (index == -1) return;
    final wasAwaiting = _awaitingConfirmation.remove(report.machineId);
    _confirmTimers.remove(report.machineId)?.cancel();

    final device = _devices[index];
    if (device.isOn != report.isOn) {
      _changes.add(
          MachineChange(device, isOn: report.isOn, requestedHere: wasAwaiting));
      _devices[index] =
          device.copyWith(isOn: report.isOn, lastUsed: DateTime.now());
      _scheduleSave();
      notifyListeners();
    } else if (wasAwaiting) {
      notifyListeners();
    }
  }

  /// Switch on every stopped machine one at a time, largest load first,
  /// waiting [interval] between machines. Starting everything at once
  /// stacks the inrush currents of several motors and can trip the main
  /// breaker. Cancelled by [cancelStartSequence] or [turnOffAllDevices].
  Future<void> startAllStaggered({Duration interval = startStagger}) async {
    final sequenceId = ++_startSequenceId;
    final queue = _devices.where((d) => !d.isOn).toList()
      ..sort((a, b) => b.powerConsumption.compareTo(a.powerConsumption));
    if (queue.isEmpty) return;

    _pendingStarts = queue.length;
    notifyListeners();

    for (var i = 0; i < queue.length; i++) {
      if (i > 0) await Future<void>.delayed(interval);
      if (sequenceId != _startSequenceId) return; // cancelled
      _pendingStarts = queue.length - i - 1;
      await turnOnDevice(queue[i].id);
    }
  }

  /// Stop an in-progress [startAllStaggered]; machines already started
  /// stay on.
  void cancelStartSequence() {
    if (_pendingStarts == 0) return;
    _startSequenceId++;
    _pendingStarts = 0;
    notifyListeners();
  }

  /// Turn off all devices, cancelling any staggered start in progress.
  Future<void> turnOffAllDevices() async {
    _startSequenceId++;
    _pendingStarts = 0;
    final running = _devices.where((d) => d.isOn).toList();
    await Future.wait(running.map((d) => _command(d, on: false)));
    notifyListeners();
  }

  /// Update device settings
  Future<void> updateDeviceSettings(
      String deviceId, Map<String, dynamic> settings) async {
    final device = getDeviceById(deviceId);
    if (device != null) {
      final updatedSettings = Map<String, dynamic>.from(device.settings ?? {})
        ..addAll(settings);
      final updatedDevice = device.copyWith(settings: updatedSettings);
      await updateDevice(updatedDevice);
    }
  }

  /// Get unique locations from devices
  List<String> getLocations() {
    return _devices.map((d) => d.location).toSet().toList();
  }

  /// Get unique device types
  List<String> getTypes() {
    return _devices.map((d) => d.type).toSet().toList();
  }

  /// Expected daily energy consumption in kWh across all machines, from
  /// each machine's scheduled hours per day.
  double get totalDailyEnergyKWh {
    return _devices.fold(0.0, (sum, d) => sum + d.dailyEnergyKWh());
  }

  /// Calculate total estimated daily cost in UGX, using the facility's
  /// current UEDCL tariff rate.
  double get totalEstimatedDailyCostUgx {
    return _tariff.costFor(totalDailyEnergyKWh);
  }

  /// Estimated monthly UEDCL bill in UGX, including the fixed charge.
  double get totalEstimatedMonthlyCostUgx {
    return _tariff.monthlyCostFor(totalDailyEnergyKWh);
  }

  /// Clear all devices (for testing or reset)
  Future<void> clearAllDevices() async {
    _devices.clear();
    _scheduleSave();
    notifyListeners();
  }

  @override
  void dispose() {
    _reportsSub.cancel();
    _power.removeListener(notifyListeners);
    if (_ownsPower) _power.dispose();
    for (final timer in _confirmTimers.values) {
      timer.cancel();
    }
    _failures.close();
    _changes.close();
    _saveDebouncer.dispose();
    super.dispose();
  }
}

// Export singleton instance
final deviceService = DeviceService(tariffService, panel: panelService);
