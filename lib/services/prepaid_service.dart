import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/prepaid.dart';
import 'device_service.dart';
import 'panel/panel_settings.dart';

/// Prepaid (Yaka) credit: the tokens bought and meter readings entered,
/// and the balance estimated from them and the panel's metered energy.
class PrepaidService extends ChangeNotifier {
  PrepaidService({
    required DeviceService devices,
    DateTime Function() clock = DateTime.now,
  })  : _devices = devices,
        _clock = clock;

  final DeviceService _devices;
  final DateTime Function() _clock;

  static const _storageKey = 'prepaid';
  static const defaultWarnDays = 3;

  bool _enabled = false;
  String _meterNumber = '';
  int _warnDays = defaultWarnDays;
  final List<PrepaidEntry> _entries = [];

  /// Whether the site is on a prepaid (Yaka) meter.
  bool get enabled => _enabled;

  /// The Yaka meter number, for buying tokens.
  String get meterNumber => _meterNumber;

  /// Warn when the credit lasts fewer than this many days.
  int get warnDays => _warnDays;

  /// Newest first.
  List<PrepaidEntry> get entries {
    final list = List.of(_entries)..sort((a, b) => b.at.compareTo(a.at));
    return list;
  }

  PrepaidBalance? get balance => PrepaidCalculator.balance(
        entries: _entries,
        log: _devices.energyHistory,
        now: _clock(),
        estimatedDailyKwh: _devices.totalDailyEnergyKWh,
      );

  double? get averagePrice => PrepaidCalculator.averagePrice(_entries);

  /// Whether credit is low: under [warnDays] of use, or used up.
  bool get isLow {
    final b = balance;
    if (!_enabled || b == null) return false;
    final days = b.daysLeft;
    return b.units <= 0 || (days != null && days < _warnDays);
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final saved = jsonDecode(prefs.getString(_storageKey) ?? '{}');
      if (saved is Map) {
        _enabled = saved['enabled'] == true;
        _meterNumber = saved['meter'] is String ? saved['meter'] as String : '';
        _warnDays = saved['warnDays'] is int
            ? saved['warnDays'] as int
            : defaultWarnDays;
        final entries = saved['entries'];
        if (entries is List) {
          _entries.addAll(entries.map(PrepaidEntry.fromJson).nonNulls);
        }
      }
    } on FormatException {
      // Start afresh.
    }
    // The balance moves with the metered energy.
    _devices.addListener(notifyListeners);
    notifyListeners();
  }

  Future<void> configure(
      {required bool enabled, String? meterNumber, int? warnDays}) async {
    _enabled = enabled;
    if (meterNumber != null) {
      _meterNumber = meterNumber.replaceAll(RegExp(r'\s'), '');
    }
    if (warnDays != null && warnDays > 0) _warnDays = warnDays;
    await _save();
  }

  /// Record a token loaded onto the meter, and optionally the balance the
  /// meter shows after loading it.
  Future<void> addPurchase({
    required double units,
    double? amountUgx,
    DateTime? at,
    double? meterShowsAfter,
  }) async {
    final when = at ?? _clock();
    _entries.add(PrepaidEntry(
      id: _newId(),
      kind: PrepaidEntryKind.purchase,
      at: when,
      units: units,
      amountUgx: amountUgx,
    ));
    if (meterShowsAfter != null) {
      // A reading just after the purchase already includes it.
      _entries.add(PrepaidEntry(
        id: _newId(),
        kind: PrepaidEntryKind.reading,
        at: when.add(const Duration(seconds: 1)),
        units: meterShowsAfter,
      ));
    }
    await _save();
  }

  /// Record the units left as the Yaka meter shows them.
  Future<void> addReading(double units, {DateTime? at}) async {
    _entries.add(PrepaidEntry(
      id: _newId(),
      kind: PrepaidEntryKind.reading,
      at: at ?? _clock(),
      units: units,
    ));
    await _save();
  }

  /// Remove an entry; returns it so it can be put back (undo).
  Future<PrepaidEntry?> remove(String id) async {
    final i = _entries.indexWhere((e) => e.id == id);
    if (i == -1) return null;
    final removed = _entries.removeAt(i);
    await _save();
    return removed;
  }

  Future<void> restore(PrepaidEntry entry) async {
    if (_entries.any((e) => e.id == entry.id)) return;
    _entries.add(entry);
    await _save();
  }

  String _newId() =>
      '${_clock().microsecondsSinceEpoch}-${PanelSettings.randomHex(4)}';

  Future<void> _save() async {
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _storageKey,
          jsonEncode({
            'enabled': _enabled,
            'meter': _meterNumber,
            'warnDays': _warnDays,
            'entries': [for (final e in _entries) e.toJson()],
          }));
    } catch (e) {
      debugPrint('Could not save prepaid credit: $e');
    }
  }

  @override
  void dispose() {
    _devices.removeListener(notifyListeners);
    super.dispose();
  }
}

final prepaidService = PrepaidService(devices: deviceService);
