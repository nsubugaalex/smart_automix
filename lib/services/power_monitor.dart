import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/energy_prices.dart';
import '../models/supply.dart';
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
    this.volts,
  });

  final double watts;

  /// The meter's cumulative energy register.
  final double kwh;
  final DateTime at;

  /// Each incomer phase's voltage; null for a phase that didn't answer.
  final List<double?>? volts;
}

/// A supply event that is new to the app, or that has just ended.
@immutable
class SupplyEventChange {
  const SupplyEventChange(this.event, {required this.isNew});

  final SupplyEvent event;

  /// False when an event the app already had has ended.
  final bool isNew;
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
    EnergyPrices prices = const FlatPrices(0),
  })  : _now = clock ?? DateTime.now,
        _prices = prices {
    _sub = telemetry.listen(_onTelemetry);
  }

  /// The panel reports every few seconds; allow a few missed reports
  /// before treating its readings as out of date.
  static const defaultMaxAge = Duration(seconds: 30);

  static const _historyKey = 'energy_history';
  static const _supplyEventsKey = 'supply_events';

  /// Supply events kept in the app (the panel only keeps its last 16).
  static const maxSupplyEvents = 200;

  /// Readings arrive every few seconds; save the history at most this
  /// often (and straight away when a new day starts).
  static const saveInterval = Duration(minutes: 1);

  // The format before the history: just today's starting register.
  static const _legacyDayKey = 'meter_day';
  static const _legacyDayStartKwhKey = 'meter_day_start_kwh';
  static const _legacyDayStartAtKey = 'meter_day_start_at';

  final Duration maxAge;
  final DateTime Function() _now;
  final EnergyPrices _prices;
  bool? _onGenerator;
  late final StreamSubscription<PanelTelemetry> _sub;
  final Map<String, PowerReading> _machines = {};
  MeterReading? _meter;
  Timer? _expiryTimer;

  EnergyLog _history = EnergyLog();
  DateTime? _lastSave;
  Timer? _saveTimer;

  SupplyState? _supplyState;
  DateTime? _supplySince;
  final Map<String, SupplyEvent> _supplyEvents = {};
  final _supplyChanges = StreamController<SupplyEventChange>.broadcast();

  /// The panel's supply protection state; null if the panel doesn't report
  /// it (no incomer meter, or older firmware).
  SupplyState? get supplyState => _supplyState;

  /// When the panel entered [supplyState], if its clock was set.
  DateTime? get supplySince => _supplySince;

  /// Supply faults and power cuts, newest first.
  List<SupplyEvent> get supplyEvents {
    final list = _supplyEvents.values.toList()
      ..sort(
          (a, b) => (b.from ?? DateTime(0)).compareTo(a.from ?? DateTime(0)));
    return list;
  }

  /// Events new to the app, and known events that have ended, for alerts.
  Stream<SupplyEventChange> get supplyEventChanges => _supplyChanges.stream;

  /// Metered energy and cost per day.
  EnergyLog get history => _history;

  /// Whether the panel is on generator power; null if it doesn't report
  /// its supply source (no changeover contact wired).
  bool? get onGenerator => _onGenerator;

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
    try {
      final events = jsonDecode(prefs.getString(_supplyEventsKey) ?? '[]');
      if (events is List) {
        for (final e in events.map(SupplyEvent.fromJson).nonNulls) {
          _supplyEvents[e.key] = e;
        }
      }
    } on FormatException {
      // Start a fresh supply log.
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
      case EnergyDayReport():
        final changed = _history.applyPanelDay(
          date: report.date,
          kwh: report.kwh,
          registerKwh: report.registerKwh,
          firstAt: report.firstAt,
          lastAt: report.lastAt,
          gridHourlyKwh: report.gridHourlyKwh,
          generatorKwh: report.generatorKwh,
          generatorSeconds: report.generatorSeconds,
          prices: _prices,
        );
        if (changed) {
          _saveSoon();
          notifyListeners();
        }
        return;
      case SupplyStatusReport():
        if (_supplyState != report.state || _supplySince != report.since) {
          _supplyState = report.state;
          _supplySince = report.since;
          notifyListeners();
        }
        return;
      case SupplyEventsReport():
        _mergeSupplyEvents(report.events);
        return;
      case MachineEventReport():
      case MachineHoursReport():
        return; // for the activity log and maintenance
      case SupplySourceReport():
        if (_onGenerator != report.onGenerator) {
          _onGenerator = report.onGenerator;
          notifyListeners();
        }
        return;
      case MachinePowerReport():
        _machines[report.machineId] =
            PowerReading(watts: report.watts, amps: report.amps, at: now);
      case MeterReport():
        _meter = MeterReading(
            watts: report.watts, kwh: report.kwh, at: now, volts: report.volts);
        final newDay = _history.record(
            registerKwh: report.kwh,
            at: now,
            prices: _prices,
            onGenerator: _onGenerator == true);
        final last = _lastSave;
        if (newDay || last == null || now.difference(last) >= saveInterval) {
          _lastSave = now;
          unawaited(_save());
        }
    }
    _expiryTimer ??= Timer.periodic(maxAge ~/ 3, (_) => removeStale());
    notifyListeners();
  }

  /// Add the panel's events the app doesn't have, and note ones that
  /// have ended. The panel resends its whole log on every connect, so
  /// known, unchanged events are ignored.
  void _mergeSupplyEvents(List<SupplyEvent> events) {
    final changes = <SupplyEventChange>[];
    for (final event in events) {
      final known = _supplyEvents[event.key];
      if (known == null) {
        changes.add(SupplyEventChange(event, isNew: true));
      } else if (known.isOngoing && !event.isOngoing) {
        changes.add(SupplyEventChange(event, isNew: false));
      } else {
        continue;
      }
      _supplyEvents[event.key] = event;
    }
    if (changes.isEmpty) return;
    while (_supplyEvents.length > maxSupplyEvents) {
      _supplyEvents.remove(supplyEvents.last.key);
    }
    unawaited(_saveSupplyEvents());
    changes.forEach(_supplyChanges.add);
    notifyListeners();
  }

  Future<void> _saveSupplyEvents() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_supplyEventsKey,
          jsonEncode([for (final e in _supplyEvents.values) e.toJson()]));
    } catch (e) {
      debugPrint('Could not save supply events: $e');
    }
  }

  /// Save once a burst of updates is over: on connecting, the broker
  /// delivers every retained day at once.
  void _saveSoon() {
    _saveTimer ??= Timer(const Duration(seconds: 2), () {
      _saveTimer = null;
      unawaited(_save());
    });
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
    if (_lastSave != null || _saveTimer != null) unawaited(_save());
    _saveTimer?.cancel();
    _sub.cancel();
    _expiryTimer?.cancel();
    _supplyChanges.close();
    super.dispose();
  }
}
