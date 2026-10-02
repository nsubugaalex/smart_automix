import 'package:flutter/material.dart';
import '../../services/security_service.dart';
import '../../widgets/common/pin_dialogs.dart';

/// Access control settings for who may remotely operate the switch panel.
class SecurityScreen extends StatelessWidget {
  const SecurityScreen({super.key});

  Future<void> _enablePin(BuildContext context) async {
    final pin = await showSetPinDialog(context);
    if (pin == null) return;
    await securityService.setPin(pin);
    if (context.mounted) _showSnack(context, 'PIN enabled');
  }

  Future<void> _disablePin(BuildContext context) async {
    final verified = await showVerifyPinDialog(
      context,
      title: 'Enter current PIN to turn it off',
    );
    if (!verified) return;
    await securityService.disablePin();
    if (context.mounted) _showSnack(context, 'PIN turned off');
  }

  Future<void> _changePin(BuildContext context) async {
    final verified =
        await showVerifyPinDialog(context, title: 'Enter current PIN');
    if (!verified || !context.mounted) return;
    final pin = await showSetPinDialog(context);
    if (pin == null) return;
    await securityService.setPin(pin);
    if (context.mounted) _showSnack(context, 'PIN changed');
  }

  void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Security')),
      body: AnimatedBuilder(
        animation: securityService,
        builder: (context, _) {
          final enabled = securityService.requirePin;
          return ListView(
            children: [
              SwitchListTile(
                title: const Text('Require PIN to start machines'),
                subtitle: Text(
                  'Ask for a PIN before switching machines on. Unlocks for '
                  '${SecurityService.unlockDuration.inMinutes} minutes after '
                  'a correct PIN.',
                ),
                value: enabled,
                onChanged: (on) =>
                    on ? _enablePin(context) : _disablePin(context),
              ),
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: const Text('Change PIN'),
                enabled: enabled,
                onTap: enabled ? () => _changePin(context) : null,
              ),
              const ListTile(
                leading: Icon(Icons.info_outline),
                subtitle: Text(
                  'Switching machines off never needs a PIN, so power can '
                  'always be cut in an emergency.',
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
