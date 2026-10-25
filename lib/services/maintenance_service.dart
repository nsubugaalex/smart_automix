import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/maintenance.dart';
import 'device_service.dart';
import 'panel/panel_link.dart';
import 'panel/panel_settings.dart';
import 'panel_service.dart';

/// Running hours per machine and the maintenance tasks that fall due on
/// them.
///
/// Hours come from the panel, which counts them in flash and is always on.
/// Without that (simulation, older firmware) the app counts them itself
/// while it can see a machine running. The standby generator's hours come
/// from the generator run time in the energy history.
class MaintenanceService extends ChangeNotifier {
  MaintenanceService({
    required DeviceService devices,
    required PanelService panel,
    DateTime Function() clock = DateTime.now,
    this.tick = const Duration(seconds: 30),
  })  : _devices = devices,
        _panel = panel,
        _clock = clock;

  final DeviceService _devices;
  final PanelService _panel;
  final DateTime Function() _clock;

  /// How often the app adds running time for machines it counts itself.
  final Duration tick;

  static const _storageKey = 'maintenance';

  final Map<String, int> _panelSeconds = {};
  final Map<String, double> _appSeconds = {};
  final List<MaintenanceTask> _tasks = [];
  StreamSubscription<PanelTelemetry>? _sub;
  Timer? _ticker;
  Timer? _saveTimer;
  DateTime? _lastTick;

  List<MaintenanceTask> get tasks => List.unmodifiable(_tasks);

  List<MaintenanceTask> tasksFor(String machineId) =>
      _tasks.where((t) => t.machineId == machineId).toList();

  /// Whether the panel counts this machine's hours (rather than the app).
  bool countedByPanel(String machineId) => _panelSeconds.containsKey(machineId);

  /// Total running hours of [machineId] (or [MaintenanceTask.generatorId]).
  double hoursOf(String machineId) {
    if (machineId == MaintenanceTask.generatorId) {
      return _devices.energyHistory.days
              .fold(0, (s, d) => s + d.generatorSeconds) /
          3600;
    }
    final panel = _panelSeconds[machineId];
    return (panel ?? _appSeconds[machineId] ?? 0) / 3600;
  }

  /// Whether the generator section applies: the panel reports its supply
  /// source, or the generator has run, or it has tasks.
  bool get hasGenerator =>
      _devices.onGenerator != null ||
      hoursOf(MaintenanceTask.generatorId) > 0 ||
      tasksFor(MaintenanceTask.generatorId).isNotEmpty;

  TaskStatus statusOf(MaintenanceTask task) =>
      task.statusAt(hoursOf(task.machineId), _clock());

  /// Tasks that are due now.
  List<MaintenanceTask> get dueTasks =>
      _tasks.where((t) => statusOf(t) == TaskStatus.due).toList();

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final saved = jsonDecode(prefs.getString(_storageKey) ?? '{}');
      if (saved is Map) {
        final tasks = saved['tasks'];
        if (tasks is List) {
          _tasks.addAll(tasks.map(MaintenanceTask.fromJson).nonNulls);
        }
        void readMap(Object? m, void Function(String, num) put) {
          if (m is! Map) return;
          for (final e in m.entries) {
            if (e.value is num) put('${e.key}', e.value as num);
          }
        }

        readMap(saved['panel'], (k, v) => _panelSeconds[k] = v.toInt());
        readMap(saved['app'], (k, v) => _appSeconds[k] = v.toDouble());
      }
    } on FormatException {
      // Start afresh.
    }
    _sub = _panel.telemetry.listen((t) {
      if (t is MachineHoursReport && _panelSeconds[t.machineId] != t.seconds) {
        _panelSeconds[t.machineId] = t.seconds;
        _changed();
      }
    });
    // Time the app was closed isn't counted: it can't know what ran.
    _lastTick = _clock();
    _ticker = Timer.periodic(tick, (_) => countAppHours());
    notifyListeners();
  }

  /// Add running time for machines the app counts itself, since the last
  /// count. Runs every [tick]; also callable from tests.
  @visibleForTesting
  void countAppHours() {
    final now = _clock();
    final elapsed = now.difference(_lastTick ?? now).inMilliseconds / 1000;
    _lastTick = now;
    // Only when the states shown are real: simulated, or confirmed live by
    // a connected panel.
    if (elapsed <= 0 || !_panel.isLive) return;
    var counted = false;
    for (final d in _devices.devices) {
      if (!d.isOn || _panelSeconds.containsKey(d.id)) continue;
      _appSeconds[d.id] = (_appSeconds[d.id] ?? 0) + elapsed;
      counted = true;
    }
    if (counted) _changed();
  }

  Future<void> addTask({
    required String machineId,
    required String title,
    int? everyHours,
    int? everyDays,
  }) async {
    _tasks.add(MaintenanceTask(
      id: '${_clock().microsecondsSinceEpoch}-${PanelSettings.randomHex(4)}',
      machineId: machineId,
      title: title.trim(),
      everyHours: everyHours,
      everyDays: everyDays,
      doneAtHours: hoursOf(machineId),
      doneOn: _clock(),
    ));
    _changed();
  }

  /// Add the suggested tasks for [machineId]'s type that it doesn't have.
  Future<void> addSuggested(String machineId, String type) async {
    final have = tasksFor(machineId).map((t) => t.title).toSet();
    for (final s in MaintenanceTask.suggestionsFor(type)) {
      if (have.contains(s.title)) continue;
      await addTask(
          machineId: machineId,
          title: s.title,
          everyHours: s.hours,
          everyDays: s.days);
    }
  }

  Future<void> updateTask(MaintenanceTask task) async {
    final i = _tasks.indexWhere((t) => t.id == task.id);
    if (i == -1) return;
    _tasks[i] = task;
    _changed();
  }

  Future<void> removeTask(String id) async {
    _tasks.removeWhere((t) => t.id == id);
    _changed();
  }

  /// Record that [id] was done now, at the machine's current hours.
  Future<void> markDone(String id) async {
    final i = _tasks.indexWhere((t) => t.id == id);
    if (i == -1) return;
    final t = _tasks[i];
    _tasks[i] = t.copyWith(doneAtHours: hoursOf(t.machineId), doneOn: _clock());
    _changed();
  }

  void _changed() {
    _saveTimer ??= Timer(const Duration(seconds: 1), () {
      _saveTimer = null;
      unawaited(_save());
    });
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _storageKey,
          jsonEncode({
            'tasks': [for (final t in _tasks) t.toJson()],
            'panel': _panelSeconds,
            'app': _appSeconds,
          }));
    } catch (e) {
      debugPrint('Could not save maintenance: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    if (_saveTimer != null) {
      _saveTimer!.cancel();
      unawaited(_save());
    }
    super.dispose();
  }
}

final maintenanceService =
    MaintenanceService(devices: deviceService, panel: panelService);
