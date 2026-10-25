// End-to-end: the app's real MQTT transport and DeviceService against
// tool/panel_simulator.dart, through a real broker.
//
// Skipped unless MQTT_E2E_HOST is set, e.g. with a local Mosquitto:
//   MQTT_E2E_HOST=localhost flutter test test/e2e
// CI runs it against Mosquitto on the runner.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_automix/models/device_model.dart';
import 'package:smart_automix/models/supply.dart';
import 'package:smart_automix/services/activity_log.dart';
import 'package:smart_automix/services/device_service.dart';
import 'package:smart_automix/services/operator_profile.dart';
import 'package:smart_automix/services/panel/mqtt_transport.dart';
import 'package:smart_automix/services/panel/panel_link.dart';
import 'package:smart_automix/services/panel/panel_settings.dart';
import 'package:smart_automix/services/panel/panel_topics.dart';
import 'package:smart_automix/services/panel_service.dart';
import 'package:smart_automix/services/tariff_service.dart';

final _host = Platform.environment['MQTT_E2E_HOST'];
final _port = int.tryParse(Platform.environment['MQTT_E2E_PORT'] ?? '') ?? 1883;

/// The Dart SDK binary itself: on Windows `dart` on the PATH is a .bat
/// wrapper, which Process.start can't run and kill() wouldn't stop.
String get _dart {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final exe =
        '$root/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}';
    if (File(exe).existsSync()) return exe;
  }
  return 'dart';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('app ↔ simulator', _endToEnd,
      skip: _host == null ? 'set MQTT_E2E_HOST to run' : false);
}

void _endToEnd() {
  // A fresh panel ID per run, so retained messages from earlier runs (or
  // other users of a shared broker) can't interfere.
  final panelId = 'e2e-${PanelSettings.randomHex(8)}';
  final topics = PanelTopics(panelId);
  final simulatorLog = <String>[];
  Process? simulator;
  PanelService? panel;
  late DeviceService devices;
  late ActivityLog activity;
  final failures = <CommandFailure>[];

  /// Polls [condition] until it holds, failing after [timeout].
  Future<void> eventually(bool Function() condition, String what,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for $what.\n'
            'Simulator output:\n${simulatorLog.join('\n')}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  bool isOn(String id) => devices.getDeviceById(id)!.isOn;

  setUpAll(() async {
    simulator = await Process.start(_dart, [
      'run',
      'tool/panel_simulator.dart',
      '--host', _host!, //
      '--port', '$_port',
      '--panel', panelId,
      '--ignore', '2',
      '--interval-s', '1',
      '--delay-ms', '100',
      '--history-days', '3',
      '--generator-hours', '0-24', // on the generator all day
      // Low voltage 30 s in (after the other tests), for the supply test.
      '--supply-fault', 'undervoltage:30:6',
      '--trip-delay-s', '2',
      '--stable-s', '3',
    ]);
    final online = Completer<void>();
    simulator!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      simulatorLog.add(line);
      if (line.contains('online.') && !online.isCompleted) online.complete();
    });
    simulator!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => simulatorLog.add('stderr: $line'));
    unawaited(simulator!.exitCode.then((code) {
      if (!online.isCompleted) {
        online.completeError(StateError(
            'Simulator exited ($code):\n${simulatorLog.join('\n')}'));
      }
    }));
    await online.future.timeout(const Duration(minutes: 2));

    SharedPreferences.setMockInitialValues({
      'panel_mode': 'mqtt',
      'panel_host': _host!,
      'panel_tcp_port': _port,
      'panel_id': panelId,
      'devices': jsonEncode([
        for (final id in ['1', '2', '3'])
          DeviceModel(
                  id: id,
                  name: 'Machine $id',
                  type: 'motor',
                  location: 'Workshop',
                  powerConsumption: 2200)
              .toJson(),
      ]),
    });
    FlutterSecureStorage.setMockInitialValues({});
    final service = panel = PanelService();
    await service.init();
    devices = DeviceService(TariffService(), panel: service);
    await devices.init();
    activity = ActivityLog(
        devices: devices, panel: service, profile: OperatorProfile());
    await activity.init();
    devices.commandFailures.listen(failures.add);
    await eventually(() => panel!.isLive, 'the app to see the panel online');
  });

  tearDownAll(() async {
    panel?.dispose();
    simulator?.kill();
  });

  test('a command is carried out and confirmed by the panel', () async {
    await devices.turnOnDevice('1');
    await eventually(() => isOn('1'), 'machine 1 to be confirmed ON');

    await devices.turnOffDevice('1');
    await eventually(() => !isOn('1'), 'machine 1 to be confirmed OFF');
    await Future<void>.delayed(ActivityLog.defaultExplainWait * 2);
    expect(
        activity.entries
            .where((e) => e.machineId == '1')
            .map((e) => e.text)
            .toList(),
        [
          'This phone switched Machine 1 OFF',
          'This phone switched Machine 1 ON'
        ],
        reason: "logged once each, the panel's echo not twice");
    expect(failures, isEmpty);
  });

  test('a relay that never answers raises "did not confirm"', () async {
    await devices.turnOnDevice('2');
    await eventually(() => failures.isNotEmpty, 'a command failure',
        timeout: DeviceService.defaultConfirmTimeout * 2);
    expect(failures.single.machineName, 'Machine 2');
    expect(isOn('2'), isFalse);
    failures.clear();
  });

  test('power readings arrive from the panel', () async {
    final reading = panel!.telemetry
        .where((t) => t is MachinePowerReport && t.machineId == '3')
        .first
        .timeout(const Duration(seconds: 10));
    expect(await reading, isA<MachinePowerReport>());
  });

  test("the panel's daily energy totals fill the app's history", () async {
    final today = DateTime.now();
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    await eventually(
        () =>
            devices.energyHistory.day(yesterday) != null &&
            devices.energyHistory.day(today) != null,
        "yesterday's and today's totals");
    final past = devices.energyHistory.day(yesterday)!;
    expect(past.kwh, greaterThan(0));
    expect(past.isCompleteAt(today), isTrue);
    expect(
        devices.energyHistory
            .day(DateTime(today.year, today.month, today.day - 3)),
        isNotNull);
    expect(past.gridHourlyKwh, hasLength(24), reason: 'hourly figures');
  });

  test('the app knows the panel is on the generator', () async {
    await eventually(() => devices.onGenerator == true, 'generator supply');
    final today = DateTime.now();
    await eventually(
        () => (devices.energyHistory.day(today)?.generatorKwh ?? 0) > 0,
        "today's generator energy",
        timeout: const Duration(seconds: 20));
  });

  test('the panel drops a late ON but still runs a late OFF', () async {
    // Send commands directly, as a delayed delivery would look.
    final sender = MqttClientTransport(
      PanelSettings(
          mode: PanelMode.mqtt, host: _host!, tcpPort: _port, panelId: panelId),
      clientId: 'smartautomix-e2e-${PanelSettings.randomHex(6)}',
    );
    await sender.connect();
    addTearDown(sender.disconnect);
    final late = DateTime.now().subtract(const Duration(minutes: 1));

    sender.publish(topics.command('3'),
        PanelTopics.encodeCommand(on: true, issuedAt: late));
    await eventually(
        () => simulatorLog.any((l) => l.contains('arrived too late')),
        'the simulator to drop the late ON');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(isOn('3'), isFalse);

    // A current ON works; then a late OFF must still switch it off.
    sender.publish(topics.command('3'),
        PanelTopics.encodeCommand(on: true, issuedAt: DateTime.now()));
    await eventually(() => isOn('3'), 'machine 3 to switch ON');
    sender.publish(topics.command('3'),
        PanelTopics.encodeCommand(on: false, issuedAt: late));
    await eventually(() => !isOn('3'), 'machine 3 to switch OFF');
  });

  test('a supply fault switches machines off until the supply is steady',
      () async {
    expect(devices.supplyState, SupplyState.ok);
    await devices.turnOnDevice('3');
    await eventually(() => isOn('3'), 'machine 3 to start');

    await eventually(() => devices.supplyState == SupplyState.undervoltage,
        'the panel to trip on low voltage',
        timeout: const Duration(seconds: 45));
    await eventually(() => !isOn('3'), 'machine 3 to be switched off');
    expect(devices.supplyAllowsStart, isFalse);

    // The panel refuses starts too, not just the app.
    final sender = MqttClientTransport(
      PanelSettings(
          mode: PanelMode.mqtt, host: _host!, tcpPort: _port, panelId: panelId),
      clientId: 'smartautomix-e2e-${PanelSettings.randomHex(6)}',
    );
    await sender.connect();
    addTearDown(sender.disconnect);
    sender.publish(topics.command('3'),
        PanelTopics.encodeCommand(on: true, issuedAt: DateTime.now()));
    await eventually(() => simulatorLog.any((l) => l.contains('start refused')),
        'the panel to refuse the start');
    expect(isOn('3'), isFalse);

    final event = devices.supplyEvents
        .firstWhere((e) => e.kind == SupplyState.undervoltage);
    expect(event.phase, 2);
    expect(event.minVolts, lessThan(200));

    await eventually(() => devices.supplyState == SupplyState.ok,
        'starts to be allowed again',
        timeout: const Duration(seconds: 20));
    expect(devices.supplyEvents.first.isOngoing, isFalse);
    expect(isOn('3'), isFalse, reason: 'never restarted automatically');
  });

  test('stopping the panel shows it offline', () async {
    simulator!.kill(ProcessSignal.sigint);
    await eventually(() => panel!.panelOnline == false, 'panel offline');
    expect(panel!.isLive, isFalse);
  }, skip: Platform.isWindows ? 'no SIGINT for child processes' : false);
}
