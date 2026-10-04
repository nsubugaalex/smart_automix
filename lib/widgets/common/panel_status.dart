import 'package:flutter/material.dart';

import '../../services/panel/panel_link.dart';
import '../../services/panel_service.dart';
import '../custom/uganda_theme.dart';

/// Icon, colour and wording for the current panel connection.
class PanelStatusInfo {
  const PanelStatusInfo(this.icon, this.color, this.label, this.detail);

  final IconData icon;
  final Color color;
  final String label;
  final String detail;

  factory PanelStatusInfo.of(PanelService panel) {
    switch (panel.status) {
      case PanelLinkStatus.simulated:
        return const PanelStatusInfo(
          Icons.science_outlined,
          UgandaTheme.warning,
          'Simulation mode',
          'Switches are simulated and do not control real machines.',
        );
      case PanelLinkStatus.connecting:
        return const PanelStatusInfo(
          Icons.sync,
          UgandaTheme.warning,
          'Connecting to panel…',
          'Machine states shown are the last known states.',
        );
      case PanelLinkStatus.disconnected:
        return PanelStatusInfo(
          Icons.cloud_off,
          UgandaTheme.danger,
          'Not connected',
          '${panel.lastError ?? 'Cannot reach the MQTT broker.'} '
              'Commands cannot be sent; states shown may be out of date.',
        );
      case PanelLinkStatus.connected:
        switch (panel.panelOnline) {
          case true:
            return const PanelStatusInfo(
              Icons.cloud_done,
              UgandaTheme.running,
              'Panel online',
              'Machine states are reported live by the switch panel.',
            );
          case false:
            return const PanelStatusInfo(
              Icons.cloud_off,
              UgandaTheme.danger,
              'Panel offline',
              'The switch panel controller is offline. Commands will not '
                  'take effect until it reconnects.',
            );
          case null:
            return const PanelStatusInfo(
              Icons.cloud_queue,
              UgandaTheme.warning,
              'Waiting for panel',
              'Connected to the broker, but the switch panel has not '
                  'reported in yet.',
            );
        }
    }
  }
}

/// App-bar indicator for the panel connection; tap for connection settings.
class PanelStatusIcon extends StatelessWidget {
  const PanelStatusIcon({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: panelService,
      builder: (context, _) {
        final info = PanelStatusInfo.of(panelService);
        return IconButton(
          tooltip: info.label,
          icon: Icon(info.icon, color: info.color),
          onPressed: onTap,
        );
      },
    );
  }
}

/// Banner explaining the connection whenever machine states aren't live
/// panel readings (simulation, connecting, disconnected, panel offline).
class PanelStatusBanner extends StatelessWidget {
  const PanelStatusBanner({
    super.key,
    required this.onOpenSettings,
    this.padding = EdgeInsets.zero,
  });

  final VoidCallback onOpenSettings;

  /// Space around the banner, only taken up while it is shown.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: panelService,
      builder: (context, _) {
        if (panelService.isLive && !panelService.isSimulated) {
          return const SizedBox.shrink();
        }
        final info = PanelStatusInfo.of(panelService);
        final card = Card(
          color: UgandaTheme.tintedCard(context, info.color),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                Icon(info.icon, color: info.color),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(info.label,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text(info.detail,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                TextButton(
                    onPressed: onOpenSettings, child: const Text('Settings')),
              ],
            ),
          ),
        );
        return Padding(padding: padding, child: card);
      },
    );
  }
}
