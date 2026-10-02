import 'package:flutter/material.dart';
import '../../models/device_model.dart';
import '../custom/uganda_theme.dart';

/// A single machine/circuit tile with a remote on/off switch, used on the
/// dashboard and control panel screens.
class DeviceCard extends StatelessWidget {
  const DeviceCard({
    super.key,
    required this.device,
    required this.onToggle,
    this.onTap,
  });

  final DeviceModel device;
  final ValueChanged<bool> onToggle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final overloaded = device.isOn && device.isOverloaded;

    return Card(
      color: overloaded ? UgandaTheme.tintedCard(context, UgandaTheme.danger, alpha: 20) : null,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: device.isOn ? UgandaTheme.running : UgandaTheme.off,
          child: Icon(device.icon, color: Colors.white),
        ),
        title: Row(
          children: [
            Flexible(child: Text(device.name)),
            if (overloaded) ...[
              const SizedBox(width: 6),
              const Icon(Icons.warning_amber, color: UgandaTheme.danger, size: 18),
            ],
          ],
        ),
        subtitle: Text(
          '${device.location} • ${device.powerConsumption.toStringAsFixed(0)} W'
          '${device.isOn ? ' • ${device.currentDrawAmps.toStringAsFixed(1)} A' : ''}',
          style: overloaded ? const TextStyle(color: UgandaTheme.danger) : null,
        ),
        trailing: Switch(
          value: device.isOn,
          onChanged: onToggle,
        ),
      ),
    );
  }
}
