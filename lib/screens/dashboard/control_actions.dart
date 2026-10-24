import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import '../../models/device_model.dart';
import '../../models/energy_prices.dart';
import '../../models/supply.dart';
import '../../services/device_service.dart';
import '../../services/security_service.dart';
import '../../services/tariff_service.dart';
import '../../widgets/common/pin_dialogs.dart';
import '../../widgets/custom/uganda_theme.dart';

/// The single path every on/off control in the UI goes through, so the
/// safety rules live in one place:
///  - switching a machine ON needs the operator PIN (when enabled);
///  - switching OFF never does — cutting power must always be possible;
///  - while the panel reports a bad supply, starts are refused with an
///    explanation (the panel refuses them too);
///  - bulk actions (Cut All / Start All) ask for confirmation first;
///  - with time-of-use billing, starting a large machine at peak time
///    shows what it costs per hour now and off-peak (once per machine per
///    day, so it informs rather than nags).

/// Explain why the panel refuses starts while the supply is bad.
Future<bool> _supplyAllowsStart(BuildContext context) async {
  if (deviceService.supplyAllowsStart) return true;
  final state = deviceService.supplyState!;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Can\'t start: ${state.label.toLowerCase()}'),
      content: Text(state.isFault
          ? 'The panel switched machines off to protect them from the bad '
              'supply, and refuses starts until it is back and steady.'
          : 'The supply is back, but the panel waits for it to stay steady '
              'before allowing starts. Try again in a minute.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  return false;
}

Future<bool> _authorizeStart(BuildContext context) async {
  if (!await _supplyAllowsStart(context)) return false;
  if (!context.mounted) return false;
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

/// Machines at least this big get the peak-time cost note.
const peakNoteMinWatts = 3000.0;

// Machines already shown the peak note today, so it isn't repeated.
final _peakNoted = <String>{};
String? _peakNotedDay;

/// The peak-time cost of running [watts] for an hour, or null when not at
/// peak (or time-of-use is off, or the rates haven't been entered).
({double nowPerHour, double offPeakPerHour, DateTime offPeakFrom})? peakCostOf(
    double watts, DateTime now) {
  final tou = tariffService.timeOfUse;
  if (tou.bandAt(now) != TouBand.peak || tou.peakRate <= tou.offPeakRate) {
    return null;
  }
  final kw = watts / 1000;
  return (
    nowPerHour: kw * tou.peakRate,
    offPeakPerHour: kw * tou.offPeakRate,
    offPeakFrom: tou.nextStartOf(TouBand.offPeak, now),
  );
}

/// Show [device]'s peak-time cost before starting it. True to go ahead.
Future<bool> _confirmPeakStart(
    BuildContext context, DeviceModel device, DateTime now) async {
  if (device.powerConsumption < peakNoteMinWatts) return true;
  final today = '${now.year}-${now.month}-${now.day}';
  if (_peakNotedDay != today) {
    _peakNoted.clear();
    _peakNotedDay = today;
  }
  if (_peakNoted.contains(device.id)) return true;
  final cost = peakCostOf(device.powerConsumption, now);
  if (cost == null) return true;
  _peakNoted.add(device.id);
  return _confirm(
    context,
    title: 'Peak rate now',
    message: '${device.name} costs about '
        '${UgandaTheme.formatUgx(cost.nowPerHour)} per hour at the peak rate, '
        'against ${UgandaTheme.formatUgx(cost.offPeakPerHour)} off-peak '
        '(from ${DateFormat.Hm().format(cost.offPeakFrom)}). '
        'Start it now anyway?',
    confirmLabel: 'Start now',
  );
}

/// Flip one machine on or off.
Future<void> toggleMachine(BuildContext context, DeviceModel device) async {
  final current = deviceService.getDeviceById(device.id);
  if (current == null) return;
  if (!current.isOn) {
    if (!await _authorizeStart(context) || !context.mounted) return;
    if (!await _confirmPeakStart(context, current, DateTime.now())) return;
  }
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

  final stoppedMachines = deviceService.devices.where((d) => !d.isOn);
  final stopped = stoppedMachines.length;
  final peak = peakCostOf(
      stoppedMachines.fold(0.0, (w, d) => w + d.powerConsumption),
      DateTime.now());
  final confirmed = await _confirm(
    context,
    title: 'Start all machines?',
    message: '$stopped machine(s) will start one at a time, largest load '
        'first, ${DeviceService.startStagger.inSeconds}s apart, to avoid '
        'tripping the main breaker. Make sure each machine is safe to run.'
        '${peak == null ? '' : '\n\nIt\'s peak time: together they cost about '
            '${UgandaTheme.formatUgx(peak.nowPerHour)} per hour now, against '
            '${UgandaTheme.formatUgx(peak.offPeakPerHour)} off-peak (from '
            '${DateFormat.Hm().format(peak.offPeakFrom)}).'}',
    confirmLabel: 'Start All',
  );
  if (confirmed) await deviceService.startAllStaggered();
}
