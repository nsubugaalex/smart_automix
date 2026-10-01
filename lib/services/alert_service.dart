import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/alert_model.dart';
import '../widgets/custom/uganda_theme.dart';
import 'device_service.dart';
import 'tariff_service.dart';

/// Notification centre for the app — currently used to keep the operator
/// informed about the UEDCL tariff: a stale rate, a confirmed rate change,
/// or the estimated daily cost crossing a threshold they set.
///
/// On mobile/desktop this also raises a system notification via
/// flutter_local_notifications; that plugin has no web implementation, so
/// system notifications are skipped (not just no-op'd) when running on web
/// and the alert still lands in the in-app Alerts screen.
class AlertService extends ChangeNotifier {
  static final AlertService _instance = AlertService._internal();
  factory AlertService() => _instance;
  AlertService._internal();

  static const _storageKey = 'alerts';

  final List<AlertModel> _alerts = [];
  final _notifications = FlutterLocalNotificationsPlugin();
  bool _notificationsReady = false;

  /// Alerts, newest first.
  List<AlertModel> get alerts {
    final sorted = List<AlertModel>.from(_alerts);
    sorted.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return List.unmodifiable(sorted);
  }

  int get unreadCount => _alerts.where((a) => !a.read).length;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_storageKey);
    if (stored != null) {
      final decoded = jsonDecode(stored) as List<dynamic>;
      _alerts
        ..clear()
        ..addAll(decoded.map((a) => AlertModel.fromJson(a as Map<String, dynamic>)));
    }

    if (!kIsWeb) {
      try {
        const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
        const iosSettings = DarwinInitializationSettings();
        await _notifications.initialize(
          const InitializationSettings(android: androidSettings, iOS: iosSettings),
        );
        _notificationsReady = true;
      } catch (e, stackTrace) {
        debugPrint('Local notifications initialization failed: $e');
        debugPrint('Stack trace: $stackTrace');
      }
    }

    // Keep tariff-related alerts current as machines are toggled/added or
    // the tariff is edited, not just when the Tariff screen is saved.
    deviceService.addListener(_recheckTariffHealth);
    tariffService.addListener(_recheckTariffHealth);

    notifyListeners();
  }

  void _recheckTariffHealth() {
    checkTariffHealth();
  }

  /// Add a new alert (always creates a fresh entry — use [upsert] for
  /// conditions that should only ever show one active alert at a time).
  Future<void> add({
    required String title,
    required String message,
    AlertSeverity severity = AlertSeverity.info,
  }) async {
    final alert = AlertModel(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      message: message,
      timestamp: DateTime.now(),
      severity: severity,
    );
    _alerts.add(alert);
    await _persist();
    notifyListeners();
    if (severity != AlertSeverity.info) {
      await _showSystemNotification(alert);
    }
  }

  /// Insert-or-replace an alert by a stable [id] (e.g. `'tariff-stale'`),
  /// so a recurring check (run each time the app opens) doesn't pile up
  /// duplicate alerts. Only re-notifies/re-surfaces-as-unread if the
  /// message actually changed.
  Future<void> upsert({
    required String id,
    required String title,
    required String message,
    AlertSeverity severity = AlertSeverity.warning,
  }) async {
    final existingIndex = _alerts.indexWhere((a) => a.id == id);
    if (existingIndex != -1 && _alerts[existingIndex].message == message) {
      return; // condition unchanged, nothing to do
    }

    final alert = AlertModel(
      id: id,
      title: title,
      message: message,
      timestamp: DateTime.now(),
      severity: severity,
    );

    if (existingIndex != -1) {
      _alerts[existingIndex] = alert;
    } else {
      _alerts.add(alert);
    }
    await _persist();
    notifyListeners();
    if (severity != AlertSeverity.info) {
      await _showSystemNotification(alert);
    }
  }

  /// Remove an alert raised by [upsert] once its condition is no longer
  /// true (e.g. the tariff was just updated, so drop the "stale" alert).
  Future<void> resolve(String id) async {
    final existed = _alerts.any((a) => a.id == id);
    if (!existed) return;
    _alerts.removeWhere((a) => a.id == id);
    await _persist();
    notifyListeners();
  }

  Future<void> markRead(String id) async {
    final index = _alerts.indexWhere((a) => a.id == id);
    if (index != -1 && !_alerts[index].read) {
      _alerts[index] = _alerts[index].copyWith(read: true);
      await _persist();
      notifyListeners();
    }
  }

  Future<void> markAllRead() async {
    var changed = false;
    for (var i = 0; i < _alerts.length; i++) {
      if (!_alerts[i].read) {
        _alerts[i] = _alerts[i].copyWith(read: true);
        changed = true;
      }
    }
    if (changed) {
      await _persist();
      notifyListeners();
    }
  }

  Future<void> dismiss(String id) async {
    _alerts.removeWhere((a) => a.id == id);
    await _persist();
    notifyListeners();
  }

  Future<void> clearAll() async {
    _alerts.clear();
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(_alerts.map((a) => a.toJson()).toList()));
  }

  @override
  void dispose() {
    deviceService.removeListener(_recheckTariffHealth);
    tariffService.removeListener(_recheckTariffHealth);
    super.dispose();
  }

  /// Re-evaluate tariff-related conditions and upsert/resolve the
  /// corresponding alerts. Call this on app start and whenever the tariff
  /// or device list changes.
  Future<void> checkTariffHealth() async {
    if (tariffService.isStale) {
      final lastUpdated = tariffService.lastUpdated;
      final days = lastUpdated == null
          ? null
          : DateTime.now().difference(lastUpdated).inDays;
      await upsert(
        id: 'tariff-stale',
        title: 'Tariff rate may be outdated',
        message: days == null
            ? 'No tariff rate has been confirmed yet. Set it in the Tariff tab '
                'from your current UEDCL bill.'
            : "Your tariff rate hasn't been confirmed in $days days. UEDCL/ERA "
                'rates change quarterly — check your latest bill.',
        severity: AlertSeverity.warning,
      );
    } else {
      await resolve('tariff-stale');
    }

    final threshold = tariffService.dailyCostAlertThreshold;
    final dailyCost = deviceService.totalEstimatedDailyCostUgx;
    if (threshold != null && dailyCost > threshold) {
      await upsert(
        id: 'tariff-cost-threshold',
        title: 'Daily cost above your limit',
        message: 'Estimated daily cost is ${UgandaTheme.formatUgx(dailyCost)}, '
            'above your ${UgandaTheme.formatUgx(threshold)} alert threshold.',
        severity: AlertSeverity.critical,
      );
    } else {
      await resolve('tariff-cost-threshold');
    }
  }

  Future<void> _showSystemNotification(AlertModel alert) async {
    if (kIsWeb || !_notificationsReady) return;
    try {
      const androidDetails = AndroidNotificationDetails(
        'tariff_alerts',
        'Tariff Alerts',
        channelDescription: 'Alerts about UEDCL tariff changes and cost thresholds',
        importance: Importance.high,
        priority: Priority.high,
      );
      const details = NotificationDetails(android: androidDetails);
      await _notifications.show(alert.id.hashCode, alert.title, alert.message, details);
    } catch (e, stackTrace) {
      debugPrint('Failed to show local notification: $e');
      debugPrint('Stack trace: $stackTrace');
    }
  }
}

final alertService = AlertService();
