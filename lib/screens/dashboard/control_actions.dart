import 'package:flutter/material.dart';
import '../../models/device_model.dart';
import '../../services/device_service.dart';
import '../../services/security_service.dart';
import '../../widgets/common/pin_dialogs.dart';
import '../../widgets/custom/uganda_theme.dart';

/// The single path every on/off control in the UI goes through, so the
/// safety rules live in one place:
///  - switching a machine ON needs the operator PIN (when enabled);
///  - switching OFF never does — cutting power must always be possible;
///  - bulk actions (Cut All / Start All) ask for confirmation first.

Future<bool> _authorizeStart(BuildContext context) async {
  if (securityService.isUnlocked) return true;
  return showVerifyPinDialog(context, title: 'PIN required to start machines');
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: UgandaTheme.red,
                  foregroundColor: Colors.white,
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Flip one machine on or off.
Future<void> toggleMachine(BuildContext context, DeviceModel device) async {
  final current = deviceService.getDeviceById(device.id);
  if (current == null) return;
  if (!current.isOn && !await _authorizeStart(context)) return;
  await deviceService.toggleDevice(device.id);
}

/// Master cut-off: switch every machine off (and abort any staggered
/// start), after confirmation. Never PIN-protected.
Future<void> cutAllMachines(BuildContext context) async {
  final running = deviceService.getActiveDevices().length;
  final pending = deviceService.pendingStarts;
  final confirmed = await _confirm(
    context,
    title: 'Cut power to all machines?',
    message: '$running running machine(s) will be switched off'
        '${pending > 0 ? ' and the start sequence ($pending waiting) cancelled' : ''}.',
    confirmLabel: 'Cut All',
    destructive: true,
  );
  if (confirmed) await deviceService.turnOffAllDevices();
}

/// Start every stopped machine one at a time, largest first, after PIN
/// (if enabled) and confirmation.
Future<void> startAllMachines(BuildContext context) async {
  if (!await _authorizeStart(context)) return;
  if (!context.mounted) return;

  final stopped = deviceService.devices.where((d) => !d.isOn).length;
  final confirmed = await _confirm(
    context,
    title: 'Start all machines?',
    message: '$stopped machine(s) will start one at a time, largest load '
        'first, ${DeviceService.startStagger.inSeconds}s apart, to avoid '
        'tripping the main breaker. Make sure each machine is safe to run.',
    confirmLabel: 'Start All',
  );
  if (confirmed) await deviceService.startAllStaggered();
}
