import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/device_model.dart';
import '../utils/debouncer.dart';
import 'tariff_service.dart';

/// Service for managing the machines/circuits wired to the industrial
/// switch panel: their on/off state, rated load, and remote control.
class DeviceService extends ChangeNotifier {
  static final DeviceService _instance = DeviceService._internal();
  factory DeviceService() => _instance;
  DeviceService._internal();

  final List<DeviceModel> _devices = [];
  bool _isLoading = false;
  String? _error;

  // Coalesces rapid mutations (e.g. flipping several switches at once)
  // into a single SharedPreferences write instead of one write per change.
  final Debouncer _saveDebouncer = Debouncer(delay: const Duration(milliseconds: 400));

  // Getters
  List<DeviceModel> get devices => List.unmodifiable(_devices);
  bool get isLoading => _isLoading;
  String? get error => _error;

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

  /// Get total power consumption of all active devices
  double get totalPowerConsumption {
    return _devices
        .where((d) => d.isOn)
        .fold(0.0, (sum, d) => sum + d.powerConsumption);
  }

  /// Total current being drawn right now across all running machines
  double get totalCurrentDrawAmps {
    return _devices.fold(0.0, (sum, d) => sum + d.currentDrawAmps);
  }

  /// Machines whose rated current exceeds their protective breaker
  List<DeviceModel> getOverloadedDevices() {
    return _devices.where((d) => d.isOverloaded).toList();
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
      final List<dynamic> decoded = jsonDecode(devicesJson);
      _devices.clear();
      _devices.addAll(
        decoded.map((d) => DeviceModel.fromJson(d as Map<String, dynamic>)).toList(),
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
    if (device != null) {
      final updatedDevice = device.copyWith(
        isOn: !device.isOn,
        lastUsed: device.isOn ? null : DateTime.now(),
      );
      await updateDevice(updatedDevice);
    }
  }

  /// Turn on a device
  Future<void> turnOnDevice(String deviceId) async {
    final device = getDeviceById(deviceId);
    if (device != null && !device.isOn) {
      final updatedDevice = device.copyWith(
        isOn: true,
        lastUsed: DateTime.now(),
      );
      await updateDevice(updatedDevice);
    }
  }

  /// Turn off a device
  Future<void> turnOffDevice(String deviceId) async {
    final device = getDeviceById(deviceId);
    if (device != null && device.isOn) {
      final updatedDevice = device.copyWith(
        isOn: false,
        lastUsed: DateTime.now(),
      );
      await updateDevice(updatedDevice);
    }
  }

  /// Turn on all devices
  Future<void> turnOnAllDevices() async {
    for (final device in _devices) {
      if (!device.isOn) {
        final updatedDevice = device.copyWith(
          isOn: true,
          lastUsed: DateTime.now(),
        );
        final index = _devices.indexWhere((d) => d.id == device.id);
        if (index != -1) {
          _devices[index] = updatedDevice;
        }
      }
    }
    _scheduleSave();
    notifyListeners();
  }

  /// Turn off all devices
  Future<void> turnOffAllDevices() async {
    for (final device in _devices) {
      if (device.isOn) {
        final updatedDevice = device.copyWith(
          isOn: false,
          lastUsed: DateTime.now(),
        );
        final index = _devices.indexWhere((d) => d.id == device.id);
        if (index != -1) {
          _devices[index] = updatedDevice;
        }
      }
    }
    _scheduleSave();
    notifyListeners();
  }

  /// Update device settings
  Future<void> updateDeviceSettings(String deviceId, Map<String, dynamic> settings) async {
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

  /// Calculate total daily energy consumption in kWh
  double get totalDailyEnergyKWh {
    return _devices.fold(0.0, (sum, d) => sum + d.dailyEnergyKWh());
  }

  /// Calculate total estimated daily cost in UGX, using the facility's
  /// current UEDCL tariff rate.
  double get totalEstimatedDailyCostUgx {
    return tariffService.costFor(totalDailyEnergyKWh);
  }

  /// Clear all devices (for testing or reset)
  Future<void> clearAllDevices() async {
    _devices.clear();
    _scheduleSave();
    notifyListeners();
  }

  /// Refresh devices (reload from storage)
  Future<void> refresh() async {
    await _loadDevices();
    notifyListeners();
  }

  @override
  void dispose() {
    _saveDebouncer.dispose();
    super.dispose();
  }
}

// Export singleton instance
final deviceService = DeviceService();