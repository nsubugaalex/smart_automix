import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'panel_settings.dart';

/// MQTT over TCP (optionally TLS) for Android, iOS and desktop.
MqttClient createMqttClient(PanelSettings settings, String clientId) {
  return MqttServerClient.withPort(settings.host, clientId, settings.tcpPort)
    ..secure = settings.useTls;
}
