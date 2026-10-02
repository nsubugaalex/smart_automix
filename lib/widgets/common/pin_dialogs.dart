import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/security_service.dart';

/// Ask for the operator PIN. Returns true once a correct PIN is entered,
/// false if the dialog is cancelled.
Future<bool> showVerifyPinDialog(
  BuildContext context, {
  String title = 'Enter PIN',
}) async {
  final verified = await showDialog<bool>(
    context: context,
    builder: (_) => _VerifyPinDialog(title: title),
  );
  return verified ?? false;
}

/// Ask the operator to choose a new PIN (entered twice). Returns the new
/// PIN, or null if cancelled.
Future<String?> showSetPinDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _SetPinDialog(),
  );
}

TextField _pinField({
  required TextEditingController controller,
  required String label,
  String? errorText,
  bool autofocus = false,
  ValueChanged<String>? onSubmitted,
}) {
  return TextField(
    controller: controller,
    autofocus: autofocus,
    obscureText: true,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    maxLength: SecurityService.maxPinLength,
    decoration: InputDecoration(
      labelText: label,
      errorText: errorText,
      border: const OutlineInputBorder(),
    ),
    onSubmitted: onSubmitted,
  );
}

class _VerifyPinDialog extends StatefulWidget {
  const _VerifyPinDialog({required this.title});

  final String title;

  @override
  State<_VerifyPinDialog> createState() => _VerifyPinDialogState();
}

class _VerifyPinDialogState extends State<_VerifyPinDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final lockout = securityService.lockoutRemaining;
    if (lockout != null) {
      setState(() => _error =
          'Too many wrong attempts. Try again in ${lockout.inSeconds + 1}s.');
      return;
    }

    if (securityService.verifyPin(_controller.text)) {
      Navigator.of(context).pop(true);
      return;
    }

    _controller.clear();
    final nowLocked = securityService.lockoutRemaining;
    setState(() => _error = nowLocked != null
        ? 'Too many wrong attempts. Locked for ${nowLocked.inSeconds + 1}s.'
        : 'Incorrect PIN');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: _pinField(
        controller: _controller,
        label: 'PIN',
        errorText: _error,
        autofocus: true,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Unlock')),
      ],
    );
  }
}

class _SetPinDialog extends StatefulWidget {
  const _SetPinDialog();

  @override
  State<_SetPinDialog> createState() => _SetPinDialogState();
}

class _SetPinDialogState extends State<_SetPinDialog> {
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _pinError;
  String? _confirmError;

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _pinController.text;
    setState(() {
      _pinError = SecurityService.isValidPin(pin)
          ? null
          : 'Use ${SecurityService.minPinLength}-${SecurityService.maxPinLength} digits';
      _confirmError = _pinError == null && _confirmController.text != pin
          ? 'PINs do not match'
          : null;
    });
    if (_pinError == null && _confirmError == null) {
      Navigator.of(context).pop(pin);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set operator PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _pinField(
            controller: _pinController,
            label: 'New PIN',
            errorText: _pinError,
            autofocus: true,
          ),
          const SizedBox(height: 8),
          _pinField(
            controller: _confirmController,
            label: 'Confirm PIN',
            errorText: _confirmError,
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
