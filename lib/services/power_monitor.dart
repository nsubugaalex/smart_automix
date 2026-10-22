import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'energy_log.dart';
import 'panel/panel_link.dart';

/// A machine's measured draw, as last reported by the panel.
@immutable
class PowerReading {
  const PowerReading({
    required this.watts,
    required this.amps,
    required this.at,
  });

  final double watts;
  final double amps;
  final DateTime at;
}

/// The supply meter's last reading.
@immutable
class MeterReading {
  const MeterReading({
    required this.watts,
    required this.kwh,
    required this.at,
  });

  final double watts;

  /// The meter's cumulative energy register.
  final double kwh;
  final DateTime at;
}

/// Keeps the latest power and meter readings from the panel's sensors.
///
/// Readings older than [maxAge] are dropped, so a sensor that stops
/// reporting falls back to nameplate estimates instead of showing a frozen
/// value. Also keeps the day-by-day [history] of metered energy and cost
/// from the meter's kWh register.
class PowerMonitor extends ChangeNotifier {
  PowerMonitor(
    Stream<PanelTelemetry> telemetry, {
    this.maxAge = defaultMaxAge,
    DateTime Function()? clock,
    double Function()? ratePerKwh,
  })  : _now = clock ?? DateTime.now,
        _rate = ratePerKwh ?? (() => 0) {
    _sub = telemetry.listen(_onTelemetry);
  }

  /// The panel reports every few seconds; allow a few missed reports
  /// before treating its readings as out of date.
  static const defaultMaxAge = Duration(seconds: 30);

  static const _historyKey = 'energy_history';

  /// Readings arrive every few seconds; save the history at most this
  /// often (and straight away when a new day starts).
  static const saveInterval = Duration(minutes: 1);

  // The format before the history: just today's starting register.
  static const _legacyDayKey = 'meter_day';
  static const _legacyDayStartKwhKey = 'meter_day_start_kwh';
  static const _legacyDayStartAtKey = 'meter_day_start_at';

  final Duration maxAge;
  final DateTime Function() _now;
  final double Function() _rate;
  late final StreamSubscription<PanelTelemetry> _sub;
  final Map<String, PowerReading> _machines = {};
  MeterReading? _meter;
  Timer? _expiryTimer;

  EnergyLog _history = EnergyLog();
  DateTime? _lastSave;

  /// Metered energy and cost per day.
  EnergyLog get history => _history;

  /// The latest reading for [machineId], or null if none is recent.
  PowerReading? machine(String machineId) {
    final reading = _machines[machineId];
    return reading != null && _isFresh(reading.at) ? reading : null;
  }

  /// The latest meter reading, or null if none is recent.
  MeterReading? get meter {
    final reading = _meter;
    return reading != null && _isFresh(reading.at) ? reading : null;
  }

  bool get hasReadings => meter != null || _machines.keys.any(_hasFresh);

  /// Today's record, if the meter has a recent reading from today.
  DailyEnergy? get _today {
    final reading = meter;
    return reading == null ? null : _history.day(reading.at);
  }

  /// Energy through the meter today. If the app first saw the meter partway
  /// through the day, this only counts from then ([energyTodaySince]).
  /// Null without a recent reading.
  double? get energyTodayKwh => _today?.kwh;

  /// When [energyTodayKwh] started counting.
  DateTime? get energyTodaySince => _today?.firstAt;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_historyKey);
    _history = saved == null ? EnergyLog() : EnergyLog.fromJson(saved);

    final legacyStart = prefs.getDouble(_legacyDayStartKwhKey);
    final legacyAt =
        DateTime.tryParse(prefs.getString(_legacyDayStartAtKey) ?? '');
    if (legacyStart != null && legacyAt != null) {
      _history.seedDay(legacyAt, registerKwh: legacyStart);
      await _save();
    }
    if (prefs.containsKey(_legacyDayKey)) {
      await prefs.remove(_legacyDayKey);
      await prefs.remove(_legacyDayStartKwhKey);
      await prefs.remove(_legacyDayStartAtKey);
    }
  }

  bool _hasFresh(String machineId) => machine(machineId) != null;

  bool _isFresh(DateTime at) => _now().difference(at) <= maxAge;

  void _onTelemetry(PanelTelemetry report) {
    final now = _now();
    switch (report) {
      case MachinePowerReport():
        _machines[report.machineId] =
            PowerReading(watts: report.watts, amps: report.amps, at: now);
      case MeterReport():
        _meter = MeterReading(watts: report.watts, kwh: report.kwh, at: now);
        final newDay = _history.record(
            registerKwh: report.kwh, at: now, ratePerKwh: _rate());
        final last = _lastSave;
        if (newDay || last == null || now.difference(last) >= saveInterval) {
          _lastSave = now;
          unawaited(_save());
        }
    }
    _expiryTimer ??= Timer.periodic(maxAge ~/ 3, (_) => removeStale());
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_historyKey, _history.toJson());
    } catch (e) {
      debugPrint('Could not save energy history: $e');
    }
  }

  /// Drop readings older than [maxAge] and tell listeners if any went.
  /// Runs periodically while readings are arriving.
  @visibleForTesting
  void removeStale() {
    final before = _machines.length + (_meter == null ? 0 : 1);
    _machines.removeWhere((_, r) => !_isFresh(r.at));
    if (_meter != null && !_isFresh(_meter!.at)) _meter = null;
    final after = _machines.length + (_meter == null ? 0 : 1);
    if (after == 0) {
      _expiryTimer?.cancel();
      _expiryTimer = null;
    }
    if (after != before) notifyListeners();
  }

  @override
  void dispose() {
    // Keep the readings since the last periodic save.
    if (_lastSave != null) unawaited(_save());
    _sub.cancel();
    _expiryTimer?.cancel();
    super.dispose();
  }
}
