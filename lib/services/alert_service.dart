import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/alert_model.dart';
import '../widgets/custom/uganda_theme.dart';
import 'device_service.dart';
import 'panel/panel_link.dart';
import 'panel/panel_settings.dart';
import 'panel_service.dart';
import 'tariff_service.dart';

/// Notification centre for the app: the UEDCL tariff (a stale rate, a
/// confirmed rate change, or the estimated daily cost crossing a threshold
/// they set), the switch-panel link, and machines measured drawing more
/// current than their breaker allows.
///
/// On Android/iOS/macOS this also raises a system notification via
/// flutter_local_notifications. System notifications are skipped on web
/// (they would need a browser permission prompt) and on platforms without
/// notification settings configured; the alert still lands in the in-app
/// Alerts screen everywhere.
class AlertService extends ChangeNotifier {
  AlertService(this._devices, this._tariff, {PanelService? panel})
      : _panel = panel;

  final DeviceService _devices;
  final TariffService _tariff;
  final PanelService? _panel;
  StreamSubscription<CommandFailure>? _failuresSub;

  // Machines currently measured over their breaker rating, so each
  // overcurrent raises one alert rather than one per reading.
  final Set<String> _overcurrent = {};

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
        ..addAll(
            decoded.map((a) => AlertModel.fromJson(a as Map<String, dynamic>)));
    }

    if (!kIsWeb) {
      try {
        const androidSettings =
            AndroidInitializationSettings('@mipmap/ic_launcher');
        const iosSettings = DarwinInitializationSettings();
        await _notifications.initialize(
          settings: const InitializationSettings(
            android: androidSettings,
            iOS: iosSettings,
            macOS: iosSettings,
          ),
        );
        _notificationsReady = true;
        // Android 13+ requires asking before showing notifications.
        await _notifications
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      } catch (e, stackTrace) {
        debugPrint('Local notifications initialization failed: $e');
        debugPrint('Stack trace: $stackTrace');
      }
    }

    // Keep tariff-related alerts current as machines are toggled/added or
    // the tariff is edited, not just when the Tariff screen is saved.
    _devices.addListener(_recheckTariffHealth);
    _devices.addListener(checkLoadHealth);
    _tariff.addListener(_recheckTariffHealth);
    _panel?.addListener(_recheckPanelHealth);
    _failuresSub ??= _devices.commandFailures.listen(
      (failure) => add(
        title: 'Command not confirmed: ${failure.machineName}',
        message: failure.reason,
        severity: AlertSeverity.warning,
      ),
    );

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
    await prefs.setString(
        _storageKey, jsonEncode(_alerts.map((a) => a.toJson()).toList()));
  }

  @override
  void dispose() {
    _devices.removeListener(_recheckTariffHealth);
    _devices.removeListener(checkLoadHealth);
    _tariff.removeListener(_recheckTariffHealth);
    _panel?.removeListener(_recheckPanelHealth);
    _failuresSub?.cancel();
    super.dispose();
  }

  /// Re-evaluate tariff-related conditions and upsert/resolve the
  /// corresponding alerts. Call this on app start and whenever the tariff
  /// or device list changes.
  Future<void> checkTariffHealth() async {
    if (_tariff.isStale) {
      final lastUpdated = _tariff.lastUpdated;
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

    final threshold = _tariff.dailyCostAlertThreshold;
    final dailyCost = _devices.totalEstimatedDailyCostUgx;
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

  /// Raise an alert when the panel measures a machine drawing more current
  /// than its breaker allows: a jammed or overloaded motor, or a fault.
  /// One alert per occurrence; it stays in the list after the load drops so
  /// the operator can see it happened.
  void checkLoadHealth() {
    final over = _devices.getMeasuredOvercurrentDevices();
    final overIds = over.map((d) => d.id).toSet();
    for (final device in over) {
      if (_overcurrent.contains(device.id)) continue;
      final load = _devices.loadOf(device);
      unawaited(add(
        title: 'Overcurrent: ${device.name}',
        message: '${device.name} is drawing '
            '${load.amps.toStringAsFixed(1)} A on a '
            '${device.breakerRatingAmps!.toStringAsFixed(0)} A breaker. '
            'Check it for a jam or fault before the breaker trips.',
        severity: AlertSeverity.critical,
      ));
    }
    _overcurrent
      ..clear()
      ..addAll(overIds);
  }

  void _recheckPanelHealth() {
    checkPanelHealth();
  }

  /// Raise one alert while the configured MQTT panel can't be reached or
  /// reports itself offline, and clear it once it's back. Simulation mode
  /// and the initial "connecting" state raise nothing.
  Future<void> checkPanelHealth() async {
    final panel = _panel;
    if (panel == null) return;
    const id = 'panel-link';
    final usingMqtt = panel.settings.mode == PanelMode.mqtt;
    String? problem;
    if (usingMqtt && panel.status == PanelLinkStatus.disconnected) {
      problem = panel.lastError ?? 'Cannot reach the MQTT broker.';
    } else if (usingMqtt &&
        panel.status == PanelLinkStatus.connected &&
        panel.panelOnline == false) {
      problem = 'The switch panel controller is offline. Machines cannot be '
          'switched remotely until it reconnects.';
    }
    if (problem == null) {
      await resolve(id);
    } else {
      await upsert(
        id: id,
        title: 'Switch panel unreachable',
        message: problem,
        severity: AlertSeverity.critical,
      );
    }
  }

  Future<void> _showSystemNotification(AlertModel alert) async {
    if (kIsWeb || !_notificationsReady) return;
    try {
      const androidDetails = AndroidNotificationDetails(
        'tariff_alerts',
        'Tariff Alerts',
        channelDescription:
            'Alerts about UEDCL tariff changes and cost thresholds',
        importance: Importance.high,
        priority: Priority.high,
      );
      const details = NotificationDetails(android: androidDetails);
      await _notifications.show(
        id: alert.id.hashCode,
        title: alert.title,
        body: alert.message,
        notificationDetails: details,
      );
    } catch (e, stackTrace) {
      debugPrint('Failed to show local notification: $e');
      debugPrint('Stack trace: $stackTrace');
    }
  }
}

final alertService =
    AlertService(deviceService, tariffService, panel: panelService);
