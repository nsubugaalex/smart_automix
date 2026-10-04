import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';

import 'mqtt_client_factory.dart';
import 'panel_settings.dart';

/// A text message received from the broker.
@immutable
class MqttTextMessage {
  const MqttTextMessage(this.topic, this.payload);

  final String topic;
  final String payload;
}

/// The minimal MQTT operations [MqttPanelLink] needs. Kept as an interface
/// so the panel logic can be unit-tested with a fake broker.
abstract class MqttTransport {
  /// Connect to the broker; throws if the connection fails.
  Future<void> connect();

  void subscribe(String topicFilter);

  void publish(String topic, String payload, {bool retain = false});

  Stream<MqttTextMessage> get messages;

  /// Emits false when the connection drops and true when it is restored.
  Stream<bool> get connectionChanges;

  Future<void> disconnect();
}

/// [MqttTransport] backed by the `mqtt_client` package: TCP on
/// Android/iOS/desktop, WebSockets in the browser.
class MqttClientTransport implements MqttTransport {
  MqttClientTransport(PanelSettings settings, {required String clientId})
      : _username = settings.username,
        _password = settings.password,
        _client = createMqttClient(settings, clientId) {
    _client
      ..logging(on: false)
      ..setProtocolV311()
      ..keepAlivePeriod = 20
      ..connectTimeoutPeriod = 8000
      ..autoReconnect = true
      ..resubscribeOnAutoReconnect = true
      ..onAutoReconnect = (() => _connection.add(false))
      ..onAutoReconnected = (() {
        _listenForUpdates();
        _connection.add(true);
      })
      ..connectionMessage =
          MqttConnectMessage().withClientIdentifier(clientId).startClean();
  }

  final MqttClient _client;
  final String _username;
  final String _password;
  final _messages = StreamController<MqttTextMessage>.broadcast();
  final _connection = StreamController<bool>.broadcast();
  Stream<List<MqttReceivedMessage<MqttMessage>>>? _updates;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updatesSub;

  @override
  Stream<MqttTextMessage> get messages => _messages.stream;

  @override
  Stream<bool> get connectionChanges => _connection.stream;

  @override
  Future<void> connect() async {
    final status = await _client.connect(
      _username.isEmpty ? null : _username,
      _password.isEmpty ? null : _password,
    );
    if (status?.state != MqttConnectionState.connected) {
      _client.disconnect();
      throw StateError(
          'Broker refused the connection (${status?.returnCode?.name})');
    }
    _listenForUpdates();
  }

  // The client may hand out a new updates stream after reconnecting.
  void _listenForUpdates() {
    final updates = _client.updates;
    if (updates == null || identical(updates, _updates)) return;
    _updatesSub?.cancel();
    _updates = updates;
    _updatesSub = updates.listen((batch) {
      for (final received in batch) {
        final message = received.payload;
        if (message is! MqttPublishMessage) continue;
        _messages.add(MqttTextMessage(
          received.topic,
          MqttPublishPayload.bytesToStringAsString(message.payload.message),
        ));
      }
    });
  }

  @override
  void subscribe(String topicFilter) {
    _client.subscribe(topicFilter, MqttQos.atLeastOnce);
  }

  @override
  void publish(String topic, String payload, {bool retain = false}) {
    final builder = MqttClientPayloadBuilder()..addString(payload);
    _client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!,
        retain: retain);
  }

  @override
  Future<void> disconnect() async {
    await _updatesSub?.cancel();
    _client.autoReconnect = false;
    _client.disconnect();
    await _messages.close();
    await _connection.close();
  }
}
