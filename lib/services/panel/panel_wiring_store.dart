import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/panel_wiring.dart';

/// Loads and saves the panel's wiring (SharedPreferences) and the WiFi and
/// panel broker passwords that go into its configuration (secure storage).
class PanelWiringStore {
  const PanelWiringStore({
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
  }) : _secure = secureStorage;

  final FlutterSecureStorage _secure;

  static const _wiringKey = 'panel_wiring';
  static const _wifiPasswordKey = 'panel_wifi_password';
  static const _panelPasswordKey = 'panel_own_broker_password';

  Future<({PanelWiring wiring, String wifiPassword, String panelPassword})>
      load() async {
    final prefs = await SharedPreferences.getInstance();
    PanelWiring wiring;
    try {
      wiring =
          PanelWiring.fromJson(jsonDecode(prefs.getString(_wiringKey) ?? '{}'));
    } on FormatException {
      wiring = const PanelWiring();
    }
    var wifi = '', panel = '';
    try {
      wifi = await _secure.read(key: _wifiPasswordKey) ?? '';
      panel = await _secure.read(key: _panelPasswordKey) ?? '';
    } catch (e) {
      debugPrint('Could not read panel passwords: $e');
    }
    return (wiring: wiring, wifiPassword: wifi, panelPassword: panel);
  }

  Future<void> save(PanelWiring wiring,
      {required String wifiPassword, required String panelPassword}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_wiringKey, jsonEncode(wiring.toJson()));
    await _secure.write(key: _wifiPasswordKey, value: wifiPassword);
    await _secure.write(key: _panelPasswordKey, value: panelPassword);
  }
}
