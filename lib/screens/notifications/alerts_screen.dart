import 'package:flutter/material.dart';
import '../../models/alert_model.dart';
import '../../services/alert_service.dart';
import '../../widgets/common/responsive_page.dart';
import '../../widgets/custom/uganda_theme.dart';

/// Notification centre — tariff staleness warnings, tariff change
/// confirmations, and daily-cost threshold alerts.
class AlertsScreen extends StatelessWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alerts'),
        actions: [
          AnimatedBuilder(
            animation: alertService,
            builder: (context, _) {
              if (alertService.alerts.isEmpty) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(Icons.done_all),
                tooltip: 'Mark all read',
                onPressed: () => alertService.markAllRead(),
              );
            },
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: alertService,
        builder: (context, _) {
          final alerts = alertService.alerts;

          if (alerts.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.notifications_none, size: 48, color: Colors.grey),
                  SizedBox(height: 8),
                  Text('No alerts', style: TextStyle(color: Colors.grey)),
                ],
              ),
            );
          }

          return ResponsivePage(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: alerts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) => _AlertTile(alert: alerts[index]),
            ),
          );
        },
      ),
    );
  }
}

class _AlertTile extends StatelessWidget {
  const _AlertTile({required this.alert});

  final AlertModel alert;

  Color get _color {
    switch (alert.severity) {
      case AlertSeverity.critical:
        return UgandaTheme.danger;
      case AlertSeverity.warning:
        return UgandaTheme.warning;
      case AlertSeverity.info:
        return UgandaTheme.running;
    }
  }

  IconData get _icon {
    switch (alert.severity) {
      case AlertSeverity.critical:
        return Icons.error;
      case AlertSeverity.warning:
        return Icons.warning_amber;
      case AlertSeverity.info:
        return Icons.info;
    }
  }

  String get _relativeTime {
    final diff = DateTime.now().difference(alert.timestamp);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey(alert.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: UgandaTheme.danger,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => alertService.dismiss(alert.id),
      child: Card(
        color: alert.read
            ? null
            : UgandaTheme.tintedCard(context, _color, alpha: 25),
        child: ListTile(
          onTap: () => alertService.markRead(alert.id),
          leading: Icon(_icon, color: _color),
          title: Text(
            alert.title,
            style: TextStyle(
                fontWeight: alert.read ? FontWeight.normal : FontWeight.bold),
          ),
          subtitle: Text(alert.message),
          trailing:
              Text(_relativeTime, style: Theme.of(context).textTheme.bodySmall),
        ),
      ),
    );
  }
}
