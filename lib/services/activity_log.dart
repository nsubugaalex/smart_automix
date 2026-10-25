import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/supply.dart';
import 'device_service.dart';
import 'operator_profile.dart';
import 'panel/panel_link.dart';
import 'panel/panel_topics.dart';
import 'panel_service.dart';
import 'power_monitor.dart';

enum ActivityKind {
  /// This phone switched a machine.
  command,

  /// This phone's command wasn't confirmed.
  commandFailed,

  /// Another phone switched a machine.
  otherPhone,

  /// Switched at the panel, or by someone unknown (older firmware).
  panel,

  /// Overload relay or E-stop, or the contactor didn't close.
  fault,

  /// Supply faults and power cuts.
  supply,

  /// Generator starting or stopping.
  generator,

  /// The panel going offline or coming back.
  link,
}

/// One line in the activity log.
@immutable
class ActivityEntry {
  const ActivityEntry({
    required this.time,
    required this.kind,
    required this.text,
    this.machineId,
  });

  final DateTime time;
  final ActivityKind kind;
  final String text;
  final String? machineId;

  Map<String, Object?> toJson() => {
        't': time.millisecondsSinceEpoch,
        'k': kind.name,
        'x': text,
        'm': machineId,
      };

  static ActivityEntry? fromJson(Object? json) {
    if (json is! Map || json['t'] is! int || json['x'] is! String) return null;
    final kind =
        ActivityKind.values.where((k) => k.name == json['k']).firstOrNull;
    if (kind == null) return null;
    return ActivityEntry(
      time: DateTime.fromMillisecondsSinceEpoch(json['t'] as int),
      kind: kind,
      text: json['x'] as String,
      machineId: json['m'] is String ? json['m'] as String : null,
    );
  }
}

/// A timeline of who switched what and when, and what the panel and the
/// supply did, kept on this phone.
///
/// The panel reports why each machine changed (an app command with the
/// operator's name, a trip, switching at the panel, supply protection). A
/// change it doesn't explain (older firmware) is still logged, as made
/// at the panel or from another phone.
class ActivityLog extends ChangeNotifier {
  ActivityLog({
    required DeviceService devices,
    required PanelService panel,
    required OperatorProfile profile,
    DateTime Function() clock = DateTime.now,
    this.explainWait = defaultExplainWait,
  })  : _devices = devices,
        _panel = panel,
        _profile = profile,
        _clock = clock;

  final DeviceService _devices;
  final PanelService _panel;
  final OperatorProfile _profile;
  final DateTime Function() _clock;

  static const _storageKey = 'activity_log';
  static const maxEntries = 500;

  /// How long to wait for the panel's explanation of a change before
  /// logging it as unexplained.
  static const defaultExplainWait = Duration(seconds: 2);
  final Duration explainWait;

  final List<ActivityEntry> _entries = [];
  final List<StreamSubscription<Object?>> _subs = [];
  final Map<String, Timer> _unexplained = {};
  final Map<String, DateTime> _explainedAt = {};
  final Map<String, ({bool on, DateTime at})> _ownChange = {};
  bool? _onGenerator;
  bool? _panelOnline;
  Timer? _saveTimer;

  /// Newest first.
  List<ActivityEntry> get entries => List.unmodifiable(_entries);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final saved = jsonDecode(prefs.getString(_storageKey) ?? '[]');
      if (saved is List) {
        _entries
          ..clear()
          ..addAll(saved.map(ActivityEntry.fromJson).nonNulls);
        _sort();
      }
    } on FormatException {
      // Start a fresh log.
    }
    _onGenerator = _devices.onGenerator;
    _panelOnline = _panel.panelOnline;
    _subs
      ..add(_devices.machineChanges.listen(_onChange))
      ..add(_devices.commandFailures.listen(_onFailure))
      ..add(_devices.supplyEventChanges.listen(_onSupply))
      ..add(_panel.telemetry.listen((t) {
        if (t is MachineEventReport) _onEvent(t);
      }));
    _devices.addListener(_watchGenerator);
    _panel.addListener(_watchPanel);
    notifyListeners();
  }

  void add(ActivityEntry entry) {
    // Newest first; among equal times, the one added last comes first.
    final at = _entries.indexWhere((e) => !e.time.isAfter(entry.time));
    _entries.insert(at == -1 ? _entries.length : at, entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    _saveTimer ??= Timer(const Duration(seconds: 1), () {
      _saveTimer = null;
      unawaited(_save());
    });
    notifyListeners();
  }

  void _log(ActivityKind kind, String text,
          {String? machineId, DateTime? at}) =>
      add(ActivityEntry(
          time: at ?? _clock(), kind: kind, text: text, machineId: machineId));

  void _sort() => _entries.sort((a, b) => b.time.compareTo(a.time));

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _storageKey, jsonEncode([for (final e in _entries) e.toJson()]));
    } catch (e) {
      debugPrint('Could not save the activity log: $e');
    }
  }

  static String _onOff(bool on) => on ? 'ON' : 'OFF';

  String _nameOf(String machineId) =>
      _devices.getDeviceById(machineId)?.name ?? 'Machine $machineId';

  void _onChange(MachineChange change) {
    final id = change.device.id;
    if (change.requestedHere) {
      _ownChange[id] = (on: change.isOn, at: _clock());
      _log(ActivityKind.command,
          '${_profile.displayName} switched ${change.device.name} ${_onOff(change.isOn)}',
          machineId: id);
      return;
    }
    // The panel's event may already have explained it, or may follow.
    final explained = _explainedAt[id];
    if (explained != null && _clock().difference(explained) < explainWait) {
      return;
    }
    _unexplained.remove(id)?.cancel();
    _unexplained[id] = Timer(explainWait, () {
      _unexplained.remove(id);
      _log(
          ActivityKind.panel,
          '${change.device.name} switched ${_onOff(change.isOn)} '
          '(at the panel or from another phone)',
          machineId: id);
    });
  }

  void _onEvent(MachineEventReport e) {
    final id = e.machineId;
    _unexplained.remove(id)?.cancel();
    _explainedAt[id] = _clock();
    final name = _nameOf(id);
    // This phone's own command echoed back: by its install tag, or (for an
    // echo without one) by matching the change it just made.
    final own = _ownChange[id];
    final mine = (e.src.isNotEmpty && e.src == _profile.installId) ||
        (e.src.isEmpty &&
            own != null &&
            own.on == e.on &&
            _clock().difference(own.at) < explainWait * 3);
    final who = e.by.isEmpty ? 'Another phone' : e.by;
    switch (e.cause) {
      case MachineEventCause.command:
        if (mine) return; // logged when it was confirmed
        _log(ActivityKind.otherPhone, '$who switched $name ${_onOff(e.on)}',
            machineId: id);
      case MachineEventCause.trip:
        _log(ActivityKind.fault,
            '$name stopped by itself: overload relay or emergency stop',
            machineId: id);
      case MachineEventCause.panel:
        _log(ActivityKind.panel, '$name switched ${_onOff(e.on)} at the panel',
            machineId: id);
      case MachineEventCause.noClose:
        _log(
            ActivityKind.fault,
            "$name didn't start: its contactor didn't close "
            '(check the coil supply and emergency stop)'
            '${mine ? '' : ' · started by $who'}',
            machineId: id);
      case MachineEventCause.refused:
        _log(ActivityKind.supply,
            'Start of $name refused: the supply was not steady',
            machineId: id);
      case MachineEventCause.supply:
        return; // the supply event itself is logged once for all machines
    }
  }

  void _onFailure(CommandFailure f) => _log(ActivityKind.commandFailed,
      '${_profile.displayName}: ${f.machineName} not confirmed. ${f.reason}');

  void _onSupply(SupplyEventChange change) {
    final e = change.event;
    final duration = e.duration;
    if (change.isNew) {
      _log(
        ActivityKind.supply,
        e.isOngoing
            ? '${e.summary}: all machines switched off'
            : '${e.summary}${duration == null ? '' : ' for ${formatDuration(duration)}'}',
        at: e.from,
      );
    } else {
      _log(
        ActivityKind.supply,
        'Supply back to normal'
        '${duration == null ? '' : ' after ${formatDuration(duration)}'}'
        '; machines stayed off',
        at: e.to,
      );
    }
  }

  void _watchGenerator() {
    final now = _devices.onGenerator;
    if (now == _onGenerator) return;
    final before = _onGenerator;
    _onGenerator = now;
    if (before == null || now == null) return;
    _log(
        ActivityKind.generator,
        now
            ? 'Generator started (changeover to generator)'
            : 'Back on grid power');
  }

  void _watchPanel() {
    final now = _panel.panelOnline;
    if (now == _panelOnline) return;
    final before = _panelOnline;
    _panelOnline = now;
    if (before == null || now == null) return;
    _log(ActivityKind.link,
        now ? 'Panel back online' : 'Panel went offline (power or network)');
  }

  /// The log as CSV, oldest first.
  String toCsv() {
    String quote(String s) => '"${s.replaceAll('"', '""')}"';
    final rows = [
      'time,kind,machine,what',
      for (final e in _entries.reversed)
        [
          e.time.toIso8601String().substring(0, 19).replaceFirst('T', ' '),
          e.kind.name,
          quote(e.machineId == null ? '' : _nameOf(e.machineId!)),
          quote(e.text),
        ].join(','),
    ];
    return '${rows.join('\n')}\n';
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    for (final t in _unexplained.values) {
      t.cancel();
    }
    _devices.removeListener(_watchGenerator);
    _panel.removeListener(_watchPanel);
    if (_saveTimer != null) {
      _saveTimer!.cancel();
      unawaited(_save());
    }
    super.dispose();
  }
}

final activityLog = ActivityLog(
    devices: deviceService, panel: panelService, profile: operatorProfile);
