import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'panel_topics.dart';

enum PanelMode { simulation, mqtt }

/// How to reach the switch panel. Simulation needs nothing else; MQTT
/// needs a broker that both this app and the panel controller connect to.
@immutable
class PanelSettings {
  const PanelSettings({
    this.mode = PanelMode.simulation,
    this.host = '',
    this.tcpPort = 1883,
    this.webSocketPort = 8080,
    this.useTls = false,
    this.username = '',
    this.password = '',
    required this.panelId,
  });

  /// Public test broker — fine for demos, never for real machines: anyone
  /// can publish to it.
  static const publicTestHost = 'broker.emqx.io';

  final PanelMode mode;
  final String host;

  /// Plain MQTT port, used on Android/iOS/desktop (TLS usually 8883).
  final int tcpPort;

  /// MQTT-over-WebSocket port, used by the web build since browsers can't
  /// open raw TCP sockets.
  final int webSocketPort;

  final bool useTls;
  final String username;
  final String password;

  /// Identifies this installation's panel in MQTT topics. Must match the
  /// ID configured on the panel controller.
  final String panelId;

  /// A fresh random panel ID, so installations sharing a broker (or the
  /// public test broker) don't control each other's machines.
  static String generatePanelId() => 'panel-${randomHex(8)}';

  /// [length] random hex digits. Built digit by digit because large
  /// integer ranges (e.g. `1 << 32`) overflow to 0 when compiled to
  /// JavaScript for the web build.
  static String randomHex(int length) {
    final random = Random.secure();
    return List.generate(length, (_) => random.nextInt(16).toRadixString(16))
        .join();
  }

  PanelSettings copyWith({
    PanelMode? mode,
    String? host,
    int? tcpPort,
    int? webSocketPort,
    bool? useTls,
    String? username,
    String? password,
    String? panelId,
  }) {
    return PanelSettings(
      mode: mode ?? this.mode,
      host: host ?? this.host,
      tcpPort: tcpPort ?? this.tcpPort,
      webSocketPort: webSocketPort ?? this.webSocketPort,
      useTls: useTls ?? this.useTls,
      username: username ?? this.username,
      password: password ?? this.password,
      panelId: panelId ?? this.panelId,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PanelSettings &&
      other.mode == mode &&
      other.host == host &&
      other.tcpPort == tcpPort &&
      other.webSocketPort == webSocketPort &&
      other.useTls == useTls &&
      other.username == username &&
      other.password == password &&
      other.panelId == panelId;

  @override
  int get hashCode => Object.hash(
      mode, host, tcpPort, webSocketPort, useTls, username, password, panelId);
}

/// Loads and saves [PanelSettings]. The broker password goes to secure
/// storage; everything else to SharedPreferences.
class PanelSettingsStore {
  const PanelSettingsStore({
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
  }) : _secure = secureStorage;

  final FlutterSecureStorage _secure;

  static const _mode = 'panel_mode';
  static const _host = 'panel_host';
  static const _tcpPort = 'panel_tcp_port';
  static const _wsPort = 'panel_ws_port';
  static const _tls = 'panel_tls';
  static const _username = 'panel_username';
  static const _panelId = 'panel_id';
  static const _password = 'panel_broker_password';

  Future<PanelSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    var panelId = prefs.getString(_panelId);
    if (panelId == null || !PanelTopics.isValidPanelId(panelId)) {
      panelId = PanelSettings.generatePanelId();
      await prefs.setString(_panelId, panelId);
    }
    String password = '';
    try {
      password = await _secure.read(key: _password) ?? '';
    } catch (e) {
      debugPrint('Could not read broker password: $e');
    }
    return PanelSettings(
      mode: PanelMode.values.firstWhere(
        (m) => m.name == prefs.getString(_mode),
        orElse: () => PanelMode.simulation,
      ),
      host: prefs.getString(_host) ?? '',
      tcpPort: prefs.getInt(_tcpPort) ?? 1883,
      webSocketPort: prefs.getInt(_wsPort) ?? 8080,
      useTls: prefs.getBool(_tls) ?? false,
      username: prefs.getString(_username) ?? '',
      password: password,
      panelId: panelId,
    );
  }

  Future<void> save(PanelSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_mode, settings.mode.name);
    await prefs.setString(_host, settings.host);
    await prefs.setInt(_tcpPort, settings.tcpPort);
    await prefs.setInt(_wsPort, settings.webSocketPort);
    await prefs.setBool(_tls, settings.useTls);
    await prefs.setString(_username, settings.username);
    await prefs.setString(_panelId, settings.panelId);
    await _secure.write(key: _password, value: settings.password);
  }
}
