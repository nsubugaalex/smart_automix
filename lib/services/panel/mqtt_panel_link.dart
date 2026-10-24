import 'dart:async';

import 'mqtt_transport.dart';
import 'panel_link.dart';
import 'panel_topics.dart';

/// [PanelLink] that talks to the panel controller through an MQTT broker,
/// using the topic contract in [PanelTopics].
class MqttPanelLink extends PanelLink {
  MqttPanelLink({
    required this.topics,
    required MqttTransport transport,
    DateTime Function() clock = DateTime.now,
  })  : _transport = transport,
        _clock = clock;

  final PanelTopics topics;
  final MqttTransport _transport;
  final DateTime Function() _clock;
  final _reports = StreamController<MachineStateReport>.broadcast();
  final _telemetry = StreamController<PanelTelemetry>.broadcast();
  StreamSubscription<MqttTextMessage>? _messagesSub;
  StreamSubscription<bool>? _connectionSub;

  PanelLinkStatus _status = PanelLinkStatus.disconnected;
  bool? _panelOnline;
  String? _lastError;
  bool _disposed = false;

  @override
  PanelLinkStatus get status => _status;

  @override
  bool? get panelOnline => _panelOnline;

  @override
  String? get lastError => _lastError;

  @override
  Stream<MachineStateReport> get stateReports => _reports.stream;

  @override
  Stream<PanelTelemetry> get telemetry => _telemetry.stream;

  @override
  Future<void> connect() async {
    if (_status == PanelLinkStatus.connecting ||
        _status == PanelLinkStatus.connected) {
      return;
    }
    _update(PanelLinkStatus.connecting, error: null);

    _messagesSub ??= _transport.messages.listen(_onMessage);
    _connectionSub ??= _transport.connectionChanges.listen((connected) {
      // The panel's status is unknown until its retained message arrives
      // again after a reconnect.
      if (!connected) _panelOnline = null;
      _update(
          connected ? PanelLinkStatus.connected : PanelLinkStatus.connecting);
    });

    try {
      await _transport.connect();
      if (_disposed) return;
      // Retained state/status messages arrive right after subscribing, so
      // the app learns the panel's real state as soon as it connects.
      _transport
        ..subscribe(topics.status)
        ..subscribe(topics.allMachineStates)
        ..subscribe(topics.allMachinePower)
        ..subscribe(topics.meter)
        ..subscribe(topics.allEnergyDays)
        ..subscribe(topics.source)
        ..subscribe(topics.supply)
        ..subscribe(topics.supplyEvents);
      _update(PanelLinkStatus.connected);
    } catch (e) {
      if (_disposed) return;
      _update(PanelLinkStatus.disconnected, error: _describe(e));
    }
  }

  void _onMessage(MqttTextMessage message) {
    if (message.topic == topics.status) {
      final online = message.payload.trim().toLowerCase() == PanelTopics.online;
      if (online != _panelOnline) {
        _panelOnline = online;
        notifyListeners();
      }
      return;
    }
    if (message.topic == topics.meter) {
      final meter = PanelTopics.parseMeter(message.payload);
      if (meter != null) {
        _telemetry.add(MeterReport(
            watts: meter.watts,
            kwh: meter.kwh,
            volts: PanelTopics.parseMeterVolts(message.payload)));
      }
      return;
    }
    if (message.topic == topics.supply) {
      final supply = PanelTopics.parseSupply(message.payload);
      if (supply != null) {
        _telemetry
            .add(SupplyStatusReport(state: supply.state, since: supply.since));
      }
      return;
    }
    if (message.topic == topics.supplyEvents) {
      final events = PanelTopics.parseSupplyEvents(message.payload);
      if (events != null) _telemetry.add(SupplyEventsReport(events));
      return;
    }
    if (message.topic == topics.source) {
      final onGenerator = PanelTopics.parseSource(message.payload);
      if (onGenerator != null) {
        _telemetry.add(SupplySourceReport(onGenerator: onGenerator));
      }
      return;
    }
    final energyDate = topics.energyDateFrom(message.topic);
    if (energyDate != null) {
      final day = PanelTopics.parseEnergyDay(message.payload);
      if (day != null) {
        _telemetry.add(EnergyDayReport(
          date: energyDate,
          kwh: day.kwh,
          registerKwh: day.registerKwh,
          firstAt: day.firstAt,
          lastAt: day.lastAt,
          gridHourlyKwh: day.gridHourlyKwh,
          generatorKwh: day.generatorKwh,
          generatorSeconds: day.generatorSeconds,
        ));
      }
      return;
    }
    final powerId = topics.machineIdFrom(message.topic, suffix: 'power');
    if (powerId != null) {
      final power = PanelTopics.parsePower(message.payload);
      if (power != null) {
        _telemetry.add(
            MachinePowerReport(powerId, watts: power.watts, amps: power.amps));
      }
      return;
    }
    final machineId = topics.machineIdFrom(message.topic, suffix: 'state');
    final isOn = PanelTopics.parseSwitch(message.payload);
    if (machineId != null && isOn != null) {
      _reports.add(MachineStateReport(machineId, isOn: isOn));
    }
  }

  @override
  Future<bool> sendCommand(String machineId, {required bool on}) async {
    if (_status != PanelLinkStatus.connected) return false;
    try {
      _transport.publish(topics.command(machineId),
          PanelTopics.encodeCommand(on: on, issuedAt: _clock()));
      return true;
    } catch (_) {
      return false;
    }
  }

  void _update(PanelLinkStatus status, {String? error = ''}) {
    if (_disposed) return;
    _status = status;
    // '' means "leave the last error as it is".
    if (error != '') _lastError = error;
    notifyListeners();
  }

  static String _describe(Object error) {
    final text = error.toString();
    if (text.contains('SocketException') ||
        text.contains('NoConnectionException')) {
      return 'Could not reach the broker. Check the address, port and network.';
    }
    if (text.contains('notAuthorized') ||
        text.contains('badUsernameOrPassword')) {
      return 'The broker rejected the username or password.';
    }
    return text;
  }

  @override
  void dispose() {
    _disposed = true;
    _messagesSub?.cancel();
    _connectionSub?.cancel();
    _transport.disconnect();
    _reports.close();
    _telemetry.close();
    super.dispose();
  }
}
