import 'package:flutter/material.dart';
import '../../models/device_model.dart';
import '../../services/device_service.dart';
import '../../widgets/common/responsive_page.dart';
import '../../widgets/custom/uganda_theme.dart';

/// Form to register a new machine/circuit on the switch panel, capturing
/// the electrical nameplate specs (voltage, phase, power factor, breaker
/// rating) needed to monitor current draw and flag overloads.
class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _locationController = TextEditingController();
  final _powerController = TextEditingController();
  final _voltageController = TextEditingController(text: '230');
  final _powerFactorController = TextEditingController(text: '0.85');
  final _breakerController = TextEditingController();
  final _hoursPerDayController = TextEditingController(text: '4');

  DeviceType _type = DeviceType.motor;
  String _phase = 'single';

  double get _previewCurrentAmps {
    final power = double.tryParse(_powerController.text.trim()) ?? 0;
    final voltage = double.tryParse(_voltageController.text.trim()) ?? 0;
    final pf = double.tryParse(_powerFactorController.text.trim()) ?? 0;
    if (power <= 0 || voltage <= 0 || pf <= 0) return 0;
    final divisor = _phase == 'three' ? (1.732 * voltage * pf) : (voltage * pf);
    return power / divisor;
  }

  @override
  void initState() {
    super.initState();
    for (final controller in [
      _powerController,
      _voltageController,
      _powerFactorController,
    ]) {
      controller.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _locationController.dispose();
    _powerController.dispose();
    _voltageController.dispose();
    _powerFactorController.dispose();
    _breakerController.dispose();
    _hoursPerDayController.dispose();
    super.dispose();
  }

  void _onPhaseChanged(String phase) {
    setState(() {
      _phase = phase;
      _voltageController.text = phase == 'three' ? '415' : '230';
    });
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    final device = DeviceModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: _nameController.text.trim(),
      type: _type.value,
      location: _locationController.text.trim(),
      powerConsumption: double.parse(_powerController.text.trim()),
      phase: _phase,
      voltage: double.parse(_voltageController.text.trim()),
      powerFactor: double.parse(_powerFactorController.text.trim()),
      breakerRatingAmps: double.tryParse(_breakerController.text.trim()),
      hoursPerDay: double.tryParse(_hoursPerDayController.text.trim()) ?? 4.0,
    );

    deviceService.addDevice(device);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final current = _previewCurrentAmps;
    final breaker = double.tryParse(_breakerController.text.trim());
    final overBreaker = breaker != null && current > breaker;

    return Scaffold(
      appBar: AppBar(title: const Text('Add Machine')),
      body: ResponsivePage(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Machine name',
                border: OutlineInputBorder(),
              ),
              validator: (value) =>
                  (value == null || value.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<DeviceType>(
              initialValue: _type,
              decoration: const InputDecoration(
                labelText: 'Machine type',
                border: OutlineInputBorder(),
              ),
              items: DeviceType.values
                  .map((t) => DropdownMenuItem(
                        value: t,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(t.icon, size: 20),
                            const SizedBox(width: 10),
                            Text(t.value),
                          ],
                        ),
                      ))
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _type = value);
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _locationController,
              decoration: const InputDecoration(
                labelText: 'Location / bay',
                border: OutlineInputBorder(),
              ),
              validator: (value) =>
                  (value == null || value.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 24),
            Text(
              'Electrical specification',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _powerController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Rated power (watts)',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) return 'Required';
                if (double.tryParse(value.trim()) == null) return 'Enter a number';
                return null;
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _phase,
                    decoration: const InputDecoration(
                      labelText: 'Phase',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'single', child: Text('Single-phase')),
                      DropdownMenuItem(value: 'three', child: Text('Three-phase')),
                    ],
                    onChanged: (value) {
                      if (value != null) _onPhaseChanged(value);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _voltageController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Voltage (V)',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) return 'Required';
                      if (double.tryParse(value.trim()) == null) return 'Enter a number';
                      return null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _powerFactorController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Power factor (0.1-1.0)',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      final pf = double.tryParse(value?.trim() ?? '');
                      if (pf == null || pf <= 0 || pf > 1) return '0.1 - 1.0';
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _breakerController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Breaker rating (A, optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _hoursPerDayController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Expected runtime (hours/day)',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) return 'Required';
                if (double.tryParse(value.trim()) == null) return 'Enter a number';
                return null;
              },
            ),
            const SizedBox(height: 16),
            Card(
              color: overBreaker ? UgandaTheme.tintedCard(context, UgandaTheme.danger, alpha: 25) : null,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      overBreaker ? Icons.warning_amber : Icons.bolt,
                      color: overBreaker
                          ? UgandaTheme.danger
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        overBreaker
                            ? 'Est. current ${current.toStringAsFixed(1)} A exceeds the '
                              '${breaker.toStringAsFixed(0)} A breaker — it will likely trip.'
                            : 'Est. current draw: ${current.toStringAsFixed(1)} A',
                        style: TextStyle(
                          color: overBreaker ? UgandaTheme.danger : null,
                          fontWeight: overBreaker ? FontWeight.bold : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.add),
              label: const Text('Add Machine'),
            ),
          ],
          ),
        ),
      ),
    );
  }
}
