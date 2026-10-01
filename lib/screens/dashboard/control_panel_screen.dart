import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/device_service.dart';
import '../../widgets/common/device_card.dart';
import '../../widgets/common/responsive_page.dart';
import '../../widgets/custom/uganda_theme.dart';

/// Remote control panel for every machine/circuit wired to the switch
/// panel: a master cut-off plus per-machine remote on/off control.
/// Body-only (no Scaffold/AppBar) — hosted inside [MainShell].
class ControlPanelBody extends StatelessWidget {
  const ControlPanelBody({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<DeviceService>(
      builder: (context, deviceService, child) {
        final devices = deviceService.devices;
        final activeCount = deviceService.getActiveDevices().length;

        return ResponsivePage(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Card(
                  color: UgandaTheme.black,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Master Control',
                                style: TextStyle(
                                  color: UgandaTheme.yellow,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              Text(
                                '$activeCount of ${devices.length} machines running',
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: UgandaTheme.red,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: activeCount == 0
                              ? null
                              : () => deviceService.turnOffAllDevices(),
                          icon: const Icon(Icons.power_settings_new),
                          label: const Text('Cut All'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: UgandaTheme.yellow,
                            side: const BorderSide(color: UgandaTheme.yellow),
                          ),
                          onPressed: activeCount == devices.length
                              ? null
                              : () => deviceService.turnOnAllDevices(),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Start All'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: devices.isEmpty
                    ? const Center(child: Text('No machines added yet'))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: devices.length,
                        itemBuilder: (context, index) {
                          final device = devices[index];
                          return Padding(
                            key: ValueKey(device.id),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: DeviceCard(
                              device: device,
                              onToggle: (_) =>
                                  deviceService.toggleDevice(device.id),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
