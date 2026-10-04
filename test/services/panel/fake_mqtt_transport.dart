import 'dart:async';

import 'package:smart_automix/services/panel/mqtt_transport.dart';

/// In-memory stand-in for an MQTT broker connection.
class FakeMqttTransport implements MqttTransport {
  FakeMqttTransport({this.failConnect = false});

  bool failConnect;
  bool connected = false;
  final subscriptions = <String>[];
  final published = <MqttTextMessage>[];
  final _messages = StreamController<MqttTextMessage>.broadcast(sync: true);
  final _connection = StreamController<bool>.broadcast(sync: true);

  @override
  Stream<MqttTextMessage> get messages => _messages.stream;

  @override
  Stream<bool> get connectionChanges => _connection.stream;

  @override
  Future<void> connect() async {
    if (failConnect) throw StateError('NoConnectionException: refused');
    connected = true;
  }

  @override
  void subscribe(String topicFilter) => subscriptions.add(topicFilter);

  @override
  void publish(String topic, String payload, {bool retain = false}) =>
      published.add(MqttTextMessage(topic, payload));

  /// Simulate the broker delivering a message to the app.
  void deliver(String topic, String payload) =>
      _messages.add(MqttTextMessage(topic, payload));

  /// Simulate the connection dropping (false) or coming back (true).
  void setConnected(bool value) {
    connected = value;
    _connection.add(value);
  }

  @override
  Future<void> disconnect() async {
    connected = false;
  }
}
