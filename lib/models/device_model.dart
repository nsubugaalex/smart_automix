import 'package:flutter/material.dart';

/// Represents a remotely-controlled machine/circuit on the industrial
/// switch panel (e.g. a workshop motor, compressor or mill fed through a
/// contactor that this app can trip remotely).
class DeviceModel {
  final String id;
  final String name;
  final String type;
  final String location;
  final bool isOn;
  final double powerConsumption; // rated load, in watts
  final String phase; // 'single' or 'three'
  final double voltage; // supply voltage, in volts
  final double powerFactor; // 0.1 - 1.0, typical for inductive industrial loads
  final double? breakerRatingAmps; // protective breaker/fuse size, if known
  final double hoursPerDay; // expected daily runtime, for cost estimation
  final DateTime? lastUsed;
  final Map<String, dynamic>? settings;

  DeviceModel({
    required this.id,
    required this.name,
    required this.type,
    required this.location,
    this.isOn = false,
    this.powerConsumption = 0.0,
    this.phase = 'single',
    this.voltage = 230.0,
    this.powerFactor = 0.85,
    this.breakerRatingAmps,
    this.hoursPerDay = 4.0,
    this.lastUsed,
    this.settings,
  });

  /// Create a copy of this device with updated fields
  DeviceModel copyWith({
    String? id,
    String? name,
    String? type,
    String? location,
    bool? isOn,
    double? powerConsumption,
    String? phase,
    double? voltage,
    double? powerFactor,
    double? breakerRatingAmps,
    bool clearBreakerRating = false,
    double? hoursPerDay,
    DateTime? lastUsed,
    Map<String, dynamic>? settings,
  }) {
    return DeviceModel(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      location: location ?? this.location,
      isOn: isOn ?? this.isOn,
      powerConsumption: powerConsumption ?? this.powerConsumption,
      phase: phase ?? this.phase,
      voltage: voltage ?? this.voltage,
      powerFactor: powerFactor ?? this.powerFactor,
      breakerRatingAmps: clearBreakerRating
          ? null
          : (breakerRatingAmps ?? this.breakerRatingAmps),
      hoursPerDay: hoursPerDay ?? this.hoursPerDay,
      lastUsed: lastUsed ?? this.lastUsed,
      settings: settings ?? this.settings,
    );
  }

  /// Convert device to JSON map
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type,
      'location': location,
      'isOn': isOn,
      'powerConsumption': powerConsumption,
      'phase': phase,
      'voltage': voltage,
      'powerFactor': powerFactor,
      'breakerRatingAmps': breakerRatingAmps,
      'hoursPerDay': hoursPerDay,
      'lastUsed': lastUsed?.toIso8601String(),
      'settings': settings,
    };
  }

  /// Create device from JSON map
  factory DeviceModel.fromJson(Map<String, dynamic> json) {
    return DeviceModel(
      id: json['id'] as String,
      name: json['name'] as String,
      type: json['type'] as String,
      location: json['location'] as String,
      isOn: json['isOn'] as bool? ?? false,
      powerConsumption: (json['powerConsumption'] as num?)?.toDouble() ?? 0.0,
      phase: json['phase'] as String? ?? 'single',
      voltage: (json['voltage'] as num?)?.toDouble() ?? 230.0,
      powerFactor: (json['powerFactor'] as num?)?.toDouble() ?? 0.85,
      breakerRatingAmps: (json['breakerRatingAmps'] as num?)?.toDouble(),
      hoursPerDay: (json['hoursPerDay'] as num?)?.toDouble() ?? 4.0,
      lastUsed: json['lastUsed'] != null
          ? DateTime.parse(json['lastUsed'] as String)
          : null,
      settings: json['settings'] as Map<String, dynamic>?,
    );
  }

  /// Icon representing this machine's type — the single source of truth
  /// used everywhere a machine is shown (dashboard, control panel, energy
  /// monitor, add-machine form).
  IconData get icon => DeviceTypeExtension.fromString(type).icon;

  /// Rated current draw in amps, from nameplate power/voltage/power factor
  /// (independent of on/off state — this is a spec, not a live reading).
  double get ratedCurrentAmps {
    if (powerConsumption <= 0 || voltage <= 0 || powerFactor <= 0) return 0;
    final divisor = phase == 'three'
        ? (1.732 * voltage * powerFactor)
        : (voltage * powerFactor);
    return powerConsumption / divisor;
  }

  /// Current actually being drawn right now (0 if switched off).
  double get currentDrawAmps => isOn ? ratedCurrentAmps : 0;

  /// Whether this machine's rated current exceeds its protective breaker,
  /// i.e. it would (or does) trip the breaker if run.
  bool get isOverloaded =>
      breakerRatingAmps != null && ratedCurrentAmps > breakerRatingAmps!;

  /// Rated apparent power in kVA. Unlike amps, kVA can be summed across
  /// single- and three-phase machines to get a facility-wide load figure.
  double get apparentPowerKva {
    if (powerConsumption <= 0 || powerFactor <= 0) return 0;
    return powerConsumption / powerFactor / 1000;
  }

  /// Apparent power being drawn right now (0 if switched off).
  double get currentApparentPowerKva => isOn ? apparentPowerKva : 0;

  /// Expected daily energy consumption in kWh over [hoursPerDay] of runtime.
  /// This is a planning estimate from the machine's schedule, so it does
  /// not depend on whether the machine happens to be on right now.
  /// Defaults to this machine's own configured [hoursPerDay] — override to
  /// model a hypothetical usage pattern.
  double dailyEnergyKWh({double? hoursPerDay}) {
    if (powerConsumption <= 0) return 0;
    return (powerConsumption * (hoursPerDay ?? this.hoursPerDay)) / 1000;
  }

  @override
  String toString() {
    return 'DeviceModel(id: $id, name: $name, type: $type, isOn: $isOn)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DeviceModel && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// Machine/circuit types found on a small-scale industrial switch panel
enum DeviceType {
  motor,
  compressor,
  welder,
  mill,
  pump,
  coldRoom,
  lathe,
  grinder,
  lighting,
  oven,
  other,
}

/// Extension to get string value from DeviceType
extension DeviceTypeExtension on DeviceType {
  String get value {
    switch (this) {
      case DeviceType.motor:
        return 'motor';
      case DeviceType.compressor:
        return 'compressor';
      case DeviceType.welder:
        return 'welder';
      case DeviceType.mill:
        return 'mill';
      case DeviceType.pump:
        return 'pump';
      case DeviceType.coldRoom:
        return 'coldroom';
      case DeviceType.lathe:
        return 'lathe';
      case DeviceType.grinder:
        return 'grinder';
      case DeviceType.lighting:
        return 'lighting';
      case DeviceType.oven:
        return 'oven';
      case DeviceType.other:
        return 'other';
    }
  }

  /// Icon representing this machine type — kept as an exhaustive switch
  /// over the enum so a new [DeviceType] can't silently end up iconless.
  IconData get icon {
    switch (this) {
      case DeviceType.motor:
        return Icons.settings;
      case DeviceType.compressor:
        return Icons.compress;
      case DeviceType.welder:
        return Icons.bolt;
      case DeviceType.mill:
        return Icons.grain;
      case DeviceType.pump:
        return Icons.water_drop;
      case DeviceType.coldRoom:
        return Icons.ac_unit;
      case DeviceType.lathe:
        return Icons.precision_manufacturing;
      case DeviceType.grinder:
        return Icons.build;
      case DeviceType.lighting:
        return Icons.lightbulb;
      case DeviceType.oven:
        return Icons.local_fire_department;
      case DeviceType.other:
        return Icons.electrical_services;
    }
  }

  static DeviceType fromString(String value) {
    switch (value.toLowerCase()) {
      case 'motor':
        return DeviceType.motor;
      case 'compressor':
        return DeviceType.compressor;
      case 'welder':
        return DeviceType.welder;
      case 'mill':
        return DeviceType.mill;
      case 'pump':
        return DeviceType.pump;
      case 'coldroom':
        return DeviceType.coldRoom;
      case 'lathe':
        return DeviceType.lathe;
      case 'grinder':
        return DeviceType.grinder;
      case 'lighting':
        return DeviceType.lighting;
      case 'oven':
        return DeviceType.oven;
      default:
        return DeviceType.other;
    }
  }
}
