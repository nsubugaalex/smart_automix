/// How urgently an alert should be presented to the operator.
enum AlertSeverity { info, warning, critical }

extension AlertSeverityX on AlertSeverity {
  static AlertSeverity fromName(String name) {
    return AlertSeverity.values.firstWhere(
      (s) => s.name == name,
      orElse: () => AlertSeverity.info,
    );
  }
}

/// A single notification shown on the Alerts screen — e.g. a tariff that
/// may be outdated, a tariff change confirmation, or a cost threshold
/// being crossed.
class AlertModel {
  final String id;
  final String title;
  final String message;
  final DateTime timestamp;
  final AlertSeverity severity;
  final bool read;

  AlertModel({
    required this.id,
    required this.title,
    required this.message,
    required this.timestamp,
    this.severity = AlertSeverity.info,
    this.read = false,
  });

  AlertModel copyWith({bool? read}) {
    return AlertModel(
      id: id,
      title: title,
      message: message,
      timestamp: timestamp,
      severity: severity,
      read: read ?? this.read,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'message': message,
        'timestamp': timestamp.toIso8601String(),
        'severity': severity.name,
        'read': read,
      };

  factory AlertModel.fromJson(Map<String, dynamic> json) => AlertModel(
        id: json['id'] as String,
        title: json['title'] as String,
        message: json['message'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        severity: AlertSeverityX.fromName(json['severity'] as String? ?? 'info'),
        read: json['read'] as bool? ?? false,
      );
}
