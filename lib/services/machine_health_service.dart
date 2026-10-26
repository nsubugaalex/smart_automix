import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/machine_health.dart';
import 'device_service.dart';
import 'energy_log.dart';
import 'panel/panel_link.dart';
import 'panel_service.dart';

/// Learns each machine's normal running current from the panel's readings
/// and reports when it drifts (see [MachineHealthAnalysis]).
class MachineHealthService extends ChangeNotifier {
  MachineHealthService({
    required DeviceService devices,
    required PanelService panel,
    DateTime Function() clock = DateTime.now,
  })  : _devices = devices,
        _panel = panel,
        _clock = clock;

  final DeviceService _devices;
  final PanelService _panel;
  final DateTime Function() _clock;

  static const _storageKey = 'machine_health';

  /// Days of daily stats kept per machine.
  static const keepDays = 60;

  /// Start-up current (motor inrush) is ignored for this long.
  static const startupIgnore = Duration(seconds: 20);

  /// Below this the machine is idling or the sensor sees noise.
  static const minAmps = 0.2;

  final Map<String, List<DayCurrent>> _days = {};
  final Map<String, String> _learnFrom = {};
  final Map<String, MachineHealthStatus> _status = {};
  StreamSubscription<PanelTelemetry>? _sub;
  Timer? _saveTimer;

  /// The analysis for [machineId] (learning until it has enough days).
  MachineHealthStatus statusOf(String machineId) =>
      _status[machineId] ?? _analyze(machineId);

  /// Machines with something unusual.
  List<String> get flagged => [
        for (final d in _devices.devices)
          if (statusOf(d.id).finding != null) d.id,
      ];

  /// Daily average running current, oldest first, for a chart.
  List<DayCurrent> daysOf(String machineId) =>
      List.unmodifiable(_days[machineId] ?? const []);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final saved = jsonDecode(prefs.getString(_storageKey) ?? '{}');
      if (saved is Map) {
        final machines = saved['machines'];
        if (machines is Map) {
          for (final e in machines.entries) {
            final m = e.value;
            if (m is! Map) continue;
            final days = m['days'];
            if (days is List) {
              _days['${e.key}'] =
                  days.map(DayCurrent.fromJson).nonNulls.toList();
            }
            if (m['from'] is String) {
              _learnFrom['${e.key}'] = m['from'] as String;
            }
          }
        }
      }
    } on FormatException {
      // Start learning afresh.
    }
    _sub = _panel.telemetry.listen((t) {
      if (t is MachinePowerReport) addSample(t.machineId, t.amps);
    });
    notifyListeners();
  }

  /// Add a current reading for [machineId], if it counts: the machine is
  /// on, past its start-up surge, and actually drawing current.
  @visibleForTesting
  void addSample(String machineId, double amps) {
    final device = _devices.getDeviceById(machineId);
    if (device == null || !device.isOn || amps < minAmps) return;
    final now = _clock();
    final started = device.lastUsed;
    if (started != null && now.difference(started) < startupIgnore) return;

    final key = EnergyLog.dateKey(now);
    final days = _days.putIfAbsent(machineId, () => []);
    if (days.isEmpty || days.last.date != key) {
      days.add(DayCurrent(key));
      if (days.length > keepDays) days.removeAt(0);
      // A new day: the previous one is complete, so re-analyse.
      final before = _status[machineId]?.finding;
      _status[machineId] = _analyze(machineId);
      if (_status[machineId]!.finding != before) notifyListeners();
    }
    days.last.add(amps);
    _saveSoon();
  }

  /// Forget what was normal and learn again from today (after a repair or
  /// new parts).
  Future<void> relearn(String machineId) async {
    _learnFrom[machineId] = EnergyLog.dateKey(_clock());
    _status[machineId] = _analyze(machineId);
    notifyListeners();
    await _save();
  }

  MachineHealthStatus _analyze(String machineId) =>
      MachineHealthAnalysis.analyze(_days[machineId] ?? const [],
          today: _clock(), learnFrom: _learnFrom[machineId]);

  void _saveSoon() {
    _saveTimer ??= Timer(const Duration(minutes: 5), () {
      _saveTimer = null;
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _storageKey,
          jsonEncode({
            'machines': {
              for (final id in {..._days.keys, ..._learnFrom.keys})
                id: {
                  'days': [
                    for (final d in _days[id] ?? const <DayCurrent>[])
                      d.toJson()
                  ],
                  if (_learnFrom[id] != null) 'from': _learnFrom[id],
                },
            },
          }));
    } catch (e) {
      debugPrint('Could not save machine health: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    if (_saveTimer != null) {
      _saveTimer!.cancel();
      unawaited(_save());
    }
    super.dispose();
  }
}

final machineHealthService =
    MachineHealthService(devices: deviceService, panel: panelService);
