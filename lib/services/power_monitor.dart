import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
/// value. Also tracks today's metered energy from the meter's kWh register.
class PowerMonitor extends ChangeNotifier {
  PowerMonitor(
    Stream<PanelTelemetry> telemetry, {
    this.maxAge = defaultMaxAge,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now {
    _sub = telemetry.listen(_onTelemetry);
  }

  /// The panel reports every few seconds; allow a few missed reports
  /// before treating its readings as out of date.
  static const defaultMaxAge = Duration(seconds: 30);

  static const _dayKey = 'meter_day';
  static const _dayStartKwhKey = 'meter_day_start_kwh';
  static const _dayStartAtKey = 'meter_day_start_at';

  final Duration maxAge;
  final DateTime Function() _now;
  late final StreamSubscription<PanelTelemetry> _sub;
  final Map<String, PowerReading> _machines = {};
  MeterReading? _meter;
  Timer? _expiryTimer;

  // The meter register at the first reading of the day, so today's energy
  // is the difference. If the app first sees the meter partway through the
  // day, today's figure only counts from then ([energyTodaySince]).
  String? _day;
  double? _dayStartKwh;
  DateTime? _dayStartAt;

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

  /// Energy through the meter today, or null without a recent reading.
  double? get energyTodayKwh {
    final reading = meter;
    final start = _dayStartKwh;
    if (reading == null || start == null || _day != _dayOf(reading.at)) {
      return null;
    }
    return reading.kwh - start;
  }

  /// When [energyTodayKwh] started counting.
  DateTime? get energyTodaySince => energyTodayKwh == null ? null : _dayStartAt;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _day = prefs.getString(_dayKey);
    _dayStartKwh = prefs.getDouble(_dayStartKwhKey);
    final at = prefs.getString(_dayStartAtKey);
    _dayStartAt = at == null ? null : DateTime.tryParse(at);
  }

  bool _hasFresh(String machineId) => machine(machineId) != null;

  bool _isFresh(DateTime at) => _now().difference(at) <= maxAge;

  static String _dayOf(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  void _onTelemetry(PanelTelemetry report) {
    final now = _now();
    switch (report) {
      case MachinePowerReport():
        _machines[report.machineId] =
            PowerReading(watts: report.watts, amps: report.amps, at: now);
      case MeterReport():
        _meter = MeterReading(watts: report.watts, kwh: report.kwh, at: now);
        _trackDay(report.kwh, now);
    }
    _expiryTimer ??= Timer.periodic(maxAge ~/ 3, (_) => removeStale());
    notifyListeners();
  }

  void _trackDay(double kwh, DateTime now) {
    final today = _dayOf(now);
    final start = _dayStartKwh;
    // A new day, or the register went backwards (meter replaced or reset).
    if (_day != today || start == null || kwh < start) {
      _day = today;
      _dayStartKwh = kwh;
      _dayStartAt = now;
      unawaited(_saveDay());
    }
  }

  Future<void> _saveDay() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dayKey, _day!);
    await prefs.setDouble(_dayStartKwhKey, _dayStartKwh!);
    await prefs.setString(_dayStartAtKey, _dayStartAt!.toIso8601String());
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
    _sub.cancel();
    _expiryTimer?.cancel();
    super.dispose();
  }
}
