import 'package:mqtt_client/mqtt_browser_client.dart';
import 'package:mqtt_client/mqtt_client.dart';

import 'panel_settings.dart';

/// MQTT over WebSockets for the web build. A page served over https can
/// only open `wss://` (TLS) connections.
MqttClient createMqttClient(PanelSettings settings, String clientId) {
  final scheme = settings.useTls ? 'wss' : 'ws';
  return MqttBrowserClient.withPort(
    '$scheme://${settings.host}/mqtt',
    clientId,
    settings.webSocketPort,
  );
}
