// Picks the right MQTT client for the platform: browsers can only use
// WebSockets, everything else connects over TCP.
export 'mqtt_client_factory_io.dart'
    if (dart.library.js_interop) 'mqtt_client_factory_web.dart';
