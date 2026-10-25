import 'dart:async';

import 'package:flutter/foundation.dart';

import 'panel/mqtt_panel_link.dart';
import 'panel/mqtt_transport.dart';
import 'panel/panel_link.dart';
import 'panel/panel_settings.dart';
import 'operator_profile.dart';
import 'panel/panel_topics.dart';

typedef PanelLinkFactory = PanelLink Function(PanelSettings settings);

/// Owns the app's connection to the switch panel: loads the connection
/// settings, keeps the active [PanelLink] (simulated or MQTT) and swaps it
/// when the settings change. Machine state reports and sensor readings from
/// whichever link is active are re-published on [stateReports] and
/// [telemetry].
class PanelService extends ChangeNotifier {
  PanelService({
    PanelSettingsStore store = const PanelSettingsStore(),
    PanelLinkFactory? linkFactory,
  })  : _store = store,
        _linkFactory = linkFactory ?? createLink {
    _attach(SimulatedPanelLink());
  }

  final PanelSettingsStore _store;
  final PanelLinkFactory _linkFactory;
  // Synchronous so simulated switches apply before sendCommand returns.
  final _reports = StreamController<MachineStateReport>.broadcast(sync: true);
  final _telemetry = StreamController<PanelTelemetry>.broadcast();

  PanelSettings _settings = const PanelSettings(panelId: 'panel-local');
  late PanelLink _link;
  StreamSubscription<MachineStateReport>? _linkReports;
  StreamSubscription<PanelTelemetry>? _linkTelemetry;

  PanelSettings get settings => _settings;
  PanelLinkStatus get status => _link.status;
  bool? get panelOnline => _link.panelOnline;
  String? get lastError => _link.lastError;
  bool get isSimulated => _link.status == PanelLinkStatus.simulated;
  bool get canSendCommands => _link.canSendCommands;

  /// Whether the switch states on screen are confirmed by a reachable
  /// panel (always true in simulation).
  bool get isLive =>
      isSimulated ||
      (_link.status == PanelLinkStatus.connected && _link.panelOnline == true);

  Stream<MachineStateReport> get stateReports => _reports.stream;
  Stream<PanelTelemetry> get telemetry => _telemetry.stream;

  /// The default link for [settings]: simulation, or MQTT via the
  /// `mqtt_client` package.
  static PanelLink createLink(PanelSettings settings) {
    if (settings.mode == PanelMode.simulation || settings.host.isEmpty) {
      return SimulatedPanelLink();
    }
    final clientId = 'smartautomix-app-${PanelSettings.randomHex(8)}';
    return MqttPanelLink(
      topics: PanelTopics(settings.panelId),
      transport: MqttClientTransport(settings, clientId: clientId),
      sender: () => (by: operatorProfile.name, src: operatorProfile.installId),
    );
  }

  Future<void> init() async {
    _settings = await _store.load();
    _replaceLink(_linkFactory(_settings));
  }

  /// Save new settings and reconnect with them.
  Future<void> applySettings(PanelSettings settings) async {
    await _store.save(settings);
    _settings = settings;
    _replaceLink(_linkFactory(settings));
  }

  /// Retry the connection (e.g. after fixing the network).
  Future<void> reconnect() => _link.connect();

  Future<bool> sendCommand(String machineId, {required bool on}) =>
      _link.sendCommand(machineId, on: on);

  void _replaceLink(PanelLink link) {
    final old = _link;
    old.removeListener(notifyListeners);
    _linkReports?.cancel();
    _linkTelemetry?.cancel();
    old.dispose();
    _attach(link);
    notifyListeners();
    // Connect in the background; status changes arrive via notifyListeners.
    unawaited(link.connect());
  }

  void _attach(PanelLink link) {
    _link = link;
    link.addListener(notifyListeners);
    _linkReports = link.stateReports.listen(_reports.add);
    _linkTelemetry = link.telemetry.listen(_telemetry.add);
  }

  @override
  void dispose() {
    _link.removeListener(notifyListeners);
    _linkReports?.cancel();
    _linkTelemetry?.cancel();
    _link.dispose();
    _reports.close();
    _telemetry.close();
    super.dispose();
  }
}

final panelService = PanelService();
