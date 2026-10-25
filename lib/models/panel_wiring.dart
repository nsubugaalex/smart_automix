import 'package:flutter/foundation.dart';

import 'device_model.dart';

/// How one machine is wired to the panel controller.
@immutable
class MachineWiring {
  const MachineWiring({
    required this.relayPin,
    this.relayActiveLow = true,
    this.feedbackPin,
    this.feedbackActiveLow = true,
    this.pzemAddress,
  });

  final int relayPin;

  /// Most relay boards switch on when their input is pulled LOW.
  final bool relayActiveLow;

  /// GPIO reading the contactor's auxiliary contact, or null for none.
  final int? feedbackPin;
  final bool feedbackActiveLow;

  /// Modbus address of the machine's PZEM-004T, or null for none.
  final int? pzemAddress;

  MachineWiring copyWith({
    int? relayPin,
    bool? relayActiveLow,
    int? Function()? feedbackPin,
    int? Function()? pzemAddress,
  }) =>
      MachineWiring(
        relayPin: relayPin ?? this.relayPin,
        relayActiveLow: relayActiveLow ?? this.relayActiveLow,
        feedbackPin: feedbackPin != null ? feedbackPin() : this.feedbackPin,
        feedbackActiveLow: feedbackActiveLow,
        pzemAddress: pzemAddress != null ? pzemAddress() : this.pzemAddress,
      );

  Map<String, Object?> toJson() => {
        'relay': relayPin,
        'relayLow': relayActiveLow,
        'feedback': feedbackPin,
        'feedbackLow': feedbackActiveLow,
        'pzem': pzemAddress,
      };

  static MachineWiring? fromJson(Object? json) {
    if (json is! Map || json['relay'] is! int) return null;
    return MachineWiring(
      relayPin: json['relay'] as int,
      relayActiveLow: json['relayLow'] != false,
      feedbackPin: json['feedback'] is int ? json['feedback'] as int : null,
      feedbackActiveLow: json['feedbackLow'] != false,
      pzemAddress: json['pzem'] is int ? json['pzem'] as int : null,
    );
  }
}

/// The panel controller's hardware set-up, used to generate its
/// `panel_config.h`. Passwords are kept apart, in secure storage.
@immutable
class PanelWiring {
  const PanelWiring({
    this.machines = const {},
    this.meterPhases = 3,
    this.generatorPin,
    this.wifiSsid = '',
    this.panelUsername = '',
    this.undervoltage = 200,
    this.overvoltage = 255,
  });

  /// GPIOs offered for relays and inputs. Left out: 0, 2, 5, 12, 14 and 15
  /// (strapping pins that flicker or must hold a level at boot, which
  /// could pull in a contactor), 1 and 3 (USB serial), 6-11 (flash),
  /// 16 and 17 (the PZEM bus) and 34-39 (input-only, no pull-up).
  static const usablePins = [25, 26, 27, 32, 33, 13, 4, 23, 22, 21, 19, 18];

  /// The PZEM bus pins, as in the firmware's template.
  static const pzemRxPin = 16;
  static const pzemTxPin = 17;

  /// Incomer meter PZEMs use 0x10 upwards; machines 1-15.
  static const meterAddressBase = 0x10;
  static const maxMachineAddress = 0x0F;

  /// Wiring per machine ID.
  final Map<String, MachineWiring> machines;

  /// Incomer meter PZEMs: 0 (none), 1 (single-phase) or 3 (three-phase).
  final int meterPhases;

  /// GPIO for the changeover switch's generator contact, or null.
  final int? generatorPin;

  final String wifiSsid;

  /// The panel's own broker account (separate from the app's).
  final String panelUsername;

  final int undervoltage;
  final int overvoltage;

  List<int> get meterAddresses =>
      [for (var i = 0; i < meterPhases; i++) meterAddressBase + i];

  PanelWiring copyWith({
    Map<String, MachineWiring>? machines,
    int? meterPhases,
    int? Function()? generatorPin,
    String? wifiSsid,
    String? panelUsername,
    int? undervoltage,
    int? overvoltage,
  }) =>
      PanelWiring(
        machines: machines ?? this.machines,
        meterPhases: meterPhases ?? this.meterPhases,
        generatorPin: generatorPin != null ? generatorPin() : this.generatorPin,
        wifiSsid: wifiSsid ?? this.wifiSsid,
        panelUsername: panelUsername ?? this.panelUsername,
        undervoltage: undervoltage ?? this.undervoltage,
        overvoltage: overvoltage ?? this.overvoltage,
      );

  /// This wiring with every machine in [devices] wired (keeping existing
  /// wiring, giving new machines the next free relay pin and PZEM
  /// address) and machines no longer in the app dropped.
  PanelWiring assignedFor(List<DeviceModel> devices) {
    final kept = {
      for (final d in devices)
        if (machines[d.id] != null) d.id: machines[d.id]!,
    };
    final usedPins = {
      for (final w in kept.values) ...[
        w.relayPin,
        if (w.feedbackPin != null) w.feedbackPin!,
      ],
      if (generatorPin != null) generatorPin!,
    };
    final usedAddresses = {
      for (final w in kept.values)
        if (w.pzemAddress != null) w.pzemAddress!,
    };
    for (final d in devices) {
      if (kept.containsKey(d.id)) continue;
      final pin = usablePins.where((p) => !usedPins.contains(p)).firstOrNull;
      if (pin == null) break; // reported by validate()
      usedPins.add(pin);
      int? address;
      for (var a = 1; a <= maxMachineAddress; a++) {
        if (!usedAddresses.contains(a)) {
          address = a;
          break;
        }
      }
      if (address != null) usedAddresses.add(address);
      kept[d.id] = MachineWiring(relayPin: pin, pzemAddress: address);
    }
    return copyWith(machines: kept);
  }

  /// Problems that would make the generated configuration wrong or unsafe,
  /// for [devices]; empty if it's ready to use.
  List<String> validate(List<DeviceModel> devices) {
    final problems = <String>[];
    final pinUsers = <int, List<String>>{};
    void use(int pin, String who) =>
        pinUsers.putIfAbsent(pin, () => []).add(who);

    for (final d in devices) {
      final w = machines[d.id];
      if (w == null) {
        problems.add('${d.name} has no relay pin: there are only '
            '${usablePins.length} usable pins.');
        continue;
      }
      use(w.relayPin, '${d.name} relay');
      if (w.feedbackPin != null) use(w.feedbackPin!, '${d.name} feedback');
      if (w.pzemAddress != null &&
          (w.pzemAddress! < 1 || w.pzemAddress! > maxMachineAddress)) {
        problems.add('${d.name}: PZEM address must be 1-$maxMachineAddress.');
      }
    }
    if (generatorPin != null) use(generatorPin!, 'generator contact');

    for (final entry in pinUsers.entries) {
      if (!usablePins.contains(entry.key)) {
        problems.add('GPIO ${entry.key} (${entry.value.join(', ')}) is not '
            'safe to use.');
      }
      if (entry.value.length > 1) {
        problems.add('GPIO ${entry.key} is used twice: '
            '${entry.value.join(' and ')}.');
      }
    }

    final addressUsers = <int, List<String>>{};
    for (final d in devices) {
      final a = machines[d.id]?.pzemAddress;
      if (a != null) addressUsers.putIfAbsent(a, () => []).add(d.name);
    }
    for (final entry in addressUsers.entries) {
      if (entry.value.length > 1) {
        problems.add('PZEM address ${entry.key} is used twice: '
            '${entry.value.join(' and ')}.');
      }
    }

    if (![0, 1, 3].contains(meterPhases)) {
      problems.add('The incomer meter needs 0, 1 or 3 PZEMs.');
    }
    if (wifiSsid.trim().isEmpty) problems.add('Enter the WiFi network name.');
    if (undervoltage < 150 ||
        undervoltage >= overvoltage ||
        overvoltage > 300) {
      problems.add('Voltage limits must be 150-300 V, low below high.');
    }
    return problems;
  }

  Map<String, Object?> toJson() => {
        'machines': {
          for (final e in machines.entries) e.key: e.value.toJson(),
        },
        'meterPhases': meterPhases,
        'generatorPin': generatorPin,
        'wifiSsid': wifiSsid,
        'panelUsername': panelUsername,
        'undervoltage': undervoltage,
        'overvoltage': overvoltage,
      };

  static PanelWiring fromJson(Object? json) {
    if (json is! Map) return const PanelWiring();
    final machines = <String, MachineWiring>{};
    final m = json['machines'];
    if (m is Map) {
      for (final e in m.entries) {
        final w = MachineWiring.fromJson(e.value);
        if (w != null) machines['${e.key}'] = w;
      }
    }
    int number(String key, int fallback) =>
        json[key] is int ? json[key] as int : fallback;
    return PanelWiring(
      machines: machines,
      meterPhases: number('meterPhases', 3),
      generatorPin:
          json['generatorPin'] is int ? json['generatorPin'] as int : null,
      wifiSsid: json['wifiSsid'] is String ? json['wifiSsid'] as String : '',
      panelUsername: json['panelUsername'] is String
          ? json['panelUsername'] as String
          : '',
      undervoltage: number('undervoltage', 200),
      overvoltage: number('overvoltage', 255),
    );
  }
}
