import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_automix/models/device_model.dart';
import 'package:smart_automix/models/panel_wiring.dart';
import 'package:smart_automix/screens/settings/panel_setup_screen.dart';
import 'package:smart_automix/services/device_service.dart';
import 'package:smart_automix/services/panel/panel_settings.dart';
import 'package:smart_automix/services/panel/panel_wiring_store.dart';
import 'package:smart_automix/services/panel_config_generator.dart';
import 'package:smart_automix/services/security_service.dart';

DeviceModel machine(String id, String name, {bool threePhase = false}) =>
    DeviceModel(
      id: id,
      name: name,
      type: 'motor',
      location: 'Workshop',
      powerConsumption: 2200,
      phase: threePhase ? 'three' : 'single',
    );

void main() {
  final devices = [
    machine('1', 'Maize mill', threePhase: true),
    machine('1761130000123', 'Welder "big"'),
    machine('3', 'Borehole pump'),
  ];

  group('PanelWiring', () {
    test('new machines get the next free safe pin and PZEM address', () {
      final wiring = const PanelWiring(wifiSsid: 'shop').assignedFor(devices);
      expect([for (final d in devices) wiring.machines[d.id]!.relayPin],
          [25, 26, 27]);
      expect([for (final d in devices) wiring.machines[d.id]!.pzemAddress],
          [1, 2, 3]);
      expect(wiring.validate(devices), isEmpty);
    });

    test('existing wiring is kept; removed machines are dropped', () {
      final wiring = PanelWiring(wifiSsid: 'shop', machines: {
        '3': const MachineWiring(relayPin: 25, pzemAddress: 1),
        'gone': const MachineWiring(relayPin: 26),
      }).assignedFor(devices);
      expect(wiring.machines['3']!.relayPin, 25);
      expect(wiring.machines['1']!.relayPin, 26, reason: '25 is taken');
      expect(wiring.machines.containsKey('gone'), isFalse);
    });

    test('flags duplicate and unsafe pins and clashing addresses', () {
      final wiring = PanelWiring(
        wifiSsid: 'shop',
        generatorPin: 27,
        machines: {
          '1': const MachineWiring(
              relayPin: 25, feedbackPin: 27, pzemAddress: 1),
          '1761130000123': const MachineWiring(relayPin: 14, pzemAddress: 1),
          '3': const MachineWiring(relayPin: 25),
        },
      );
      final problems = wiring.validate(devices).join('\n');
      expect(problems, contains('GPIO 25 is used twice'));
      expect(problems, contains('GPIO 27 is used twice'));
      expect(problems, contains('GPIO 14'));
      expect(problems, contains('not safe'));
      expect(problems, contains('PZEM address 1 is used twice'));
    });

    test('more machines than safe pins is reported', () {
      final many = [for (var i = 0; i < 14; i++) machine('$i', 'M$i')];
      final wiring = const PanelWiring(wifiSsid: 'shop').assignedFor(many);
      expect(wiring.validate(many).join(), contains('only 12 usable pins'));
    });

    test('WiFi name and voltage limits are required to be sensible', () {
      final wiring = const PanelWiring(undervoltage: 260, overvoltage: 250)
          .assignedFor(devices);
      final problems = wiring.validate(devices).join('\n');
      expect(problems, contains('WiFi network name'));
      expect(problems, contains('Voltage limits'));
    });

    test('JSON round trip', () {
      final wiring =
          const PanelWiring(wifiSsid: 'shop', meterPhases: 1, generatorPin: 4)
              .assignedFor(devices);
      final copy = PanelWiring.fromJson(wiring.toJson());
      expect(copy.toJson(), wiring.toJson());
    });
  });

  test('store keeps passwords apart from the wiring', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    const store = PanelWiringStore();
    await store.save(const PanelWiring(wifiSsid: 'shop'),
        wifiPassword: 'wifi-secret', panelPassword: 'mqtt-secret');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('panel_wiring'), isNot(contains('secret')));
    final loaded = await store.load();
    expect(loaded.wiring.wifiSsid, 'shop');
    expect(loaded.wifiPassword, 'wifi-secret');
    expect(loaded.panelPassword, 'mqtt-secret');
  });

  group('generated panel_config.h', () {
    final wiring = const PanelWiring(
      wifiSsid: r'Shop "WiFi" \ 2',
      panelUsername: 'site1-panel',
      meterPhases: 3,
      generatorPin: 4,
      undervoltage: 195,
    ).assignedFor(devices);
    final config = PanelConfigGenerator.generate(
      settings: const PanelSettings(
        mode: PanelMode.mqtt,
        host: '192.168.1.20',
        tcpPort: 1883,
        panelId: 'panel-1a2b3c4d',
      ),
      wiring: wiring,
      devices: devices,
      wifiPassword: 'pa"ss',
      panelPassword: 'secret',
      now: DateTime(2026, 10, 25, 9, 30),
    );

    test('matches the app: panel ID, broker, machines', () {
      expect(config, contains('#define PANEL_ID "panel-1a2b3c4d"'));
      expect(config, contains('#define MQTT_HOST "192.168.1.20"'));
      expect(config, contains('#define MQTT_USERNAME "site1-panel"'));
      expect(
          config,
          contains(
              '{"1", 25, true, NO_PIN, true, 0x01, true},  // Maize mill'));
      expect(config,
          contains('{"1761130000123", 26, true, NO_PIN, true, 0x02, false},'));
      expect(config, contains('#define GENERATOR_PIN 4'));
      expect(config, contains('#define UNDERVOLTAGE_V 195'));
      expect(config, contains('METER_PZEMS = {0x10, 0x11, 0x12};'));
    });

    test('escapes strings', () {
      expect(config, contains(r'#define WIFI_SSID "Shop \"WiFi\" \\ 2"'));
      expect(config, contains(r'#define WIFI_PASSWORD "pa\"ss"'));
    });

    // Writes the header for a firmware build check:
    //   PANEL_CONFIG_OUT=<path> flutter test test/panel_setup_test.dart
    test('write for a firmware build', () {
      File(Platform.environment['PANEL_CONFIG_OUT']!).writeAsStringSync(config);
    }, skip: Platform.environment['PANEL_CONFIG_OUT'] == null);
  });

  testWidgets('screen lists every machine and blocks copying without a broker',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await deviceService.init(); // demo machines
    await securityService.init(); // no PIN
    await tester.binding.setSurfaceSize(const Size(420, 3000));
    await tester.pumpWidget(const MaterialApp(home: PanelSetupScreen()));
    await tester.pumpAndSettle();

    for (final d in deviceService.devices) {
      expect(find.textContaining(d.name), findsWidgets);
    }
    expect(find.textContaining('Set up the MQTT broker'), findsOneWidget);
    final copy = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Copy panel_config.h'));
    expect(copy.onPressed, isNull);
  });
}
