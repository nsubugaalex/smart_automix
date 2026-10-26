import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/panel_wiring.dart';
import '../../services/device_service.dart';
import '../../services/panel/panel_settings.dart';
import '../../services/panel/panel_wiring_store.dart';
import '../../services/panel_config_generator.dart';
import '../../services/panel_service.dart';
import '../../services/security_service.dart';
import '../../widgets/common/pin_dialogs.dart';
import '../../widgets/custom/uganda_theme.dart';

/// Wiring for the panel controller, and the firmware configuration
/// (`panel_config.h`) generated from it and the app's machines, so the IDs,
/// pins and broker details always match the app.
class PanelSetupScreen extends StatefulWidget {
  const PanelSetupScreen({super.key, this.store = const PanelWiringStore()});

  final PanelWiringStore store;

  @override
  State<PanelSetupScreen> createState() => _PanelSetupScreenState();
}

class _PanelSetupScreenState extends State<PanelSetupScreen> {
  PanelWiring? _wiring;
  final _ssid = TextEditingController();
  final _wifiPassword = TextEditingController();
  final _username = TextEditingController();
  final _panelPassword = TextEditingController();
  final _under = TextEditingController();
  final _over = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    for (final c in [
      _ssid,
      _wifiPassword,
      _username,
      _panelPassword,
      _under,
      _over
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The configuration holds passwords, so it's PIN-protected like the
  /// network settings.
  Future<void> _open() async {
    if (!securityService.isUnlocked) {
      final ok = await showVerifyPinDialog(context,
          title: 'PIN required for the panel setup');
      if (!mounted) return;
      if (!ok) {
        Navigator.of(context).pop();
        return;
      }
    }
    final loaded = await widget.store.load();
    if (!mounted) return;
    final wiring = loaded.wiring.assignedFor(deviceService.devices);
    _ssid.text = wiring.wifiSsid;
    _wifiPassword.text = loaded.wifiPassword;
    _username.text = wiring.panelUsername;
    _panelPassword.text = loaded.panelPassword;
    _under.text = '${wiring.undervoltage}';
    _over.text = '${wiring.overvoltage}';
    setState(() => _wiring = wiring);
  }

  PanelWiring get _current => _wiring!.copyWith(
        wifiSsid: _ssid.text.trim(),
        panelUsername: _username.text.trim(),
        undervoltage: int.tryParse(_under.text.trim()) ?? 0,
        overvoltage: int.tryParse(_over.text.trim()) ?? 0,
      );

  void _setMachine(String id, MachineWiring wiring) => setState(() {
        _wiring =
            _wiring!.copyWith(machines: {..._wiring!.machines, id: wiring});
      });

  Future<void> _save() => widget.store.save(_current,
      wifiPassword: _wifiPassword.text, panelPassword: _panelPassword.text);

  String _config() => PanelConfigGenerator.generate(
        settings: panelService.settings,
        wiring: _current,
        devices: deviceService.devices,
        wifiPassword: _wifiPassword.text,
        panelPassword: _panelPassword.text,
        now: DateTime.now(),
      );

  Future<void> _copy() async {
    await _save();
    await Clipboard.setData(ClipboardData(text: _config()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('panel_config.h copied. Paste it into '
            'firmware/esp32-panel/include/panel_config.h and flash.')));
  }

  @override
  Widget build(BuildContext context) {
    final wiring = _wiring;
    return Scaffold(
      appBar: AppBar(title: const Text('Panel setup')),
      body: wiring == null
          ? const Center(child: CircularProgressIndicator())
          : _body(context, wiring),
    );
  }

  Widget _body(BuildContext context, PanelWiring wiring) {
    final theme = Theme.of(context);
    final devices = deviceService.devices;
    final settings = panelService.settings;
    final problems = [
      if (settings.mode != PanelMode.mqtt || settings.host.isEmpty)
        'Set up the MQTT broker in Settings > Network first.',
      ..._current.validate(devices),
    ];
    final publicBroker = settings.host == PanelSettings.publicTestHost;

    Widget heading(String text) => Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 8),
          child: Text(text,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
        );
    Widget field(TextEditingController c, String label,
            {bool secret = false, bool number = false}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: c,
            obscureText: secret,
            keyboardType: number ? TextInputType.number : null,
            decoration: InputDecoration(
                labelText: label, border: const OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
        );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Fill in how the panel is wired, then copy the generated '
          'configuration into the firmware project before flashing. Machine '
          'IDs, the panel ID and the broker come from the app, so they '
          'always match.',
          style: theme.textTheme.bodyMedium,
        ),
        if (publicBroker)
          Card(
            color: UgandaTheme.tintedCard(context, UgandaTheme.danger),
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text('The app is set to the public test broker. Anyone '
                  'can send commands there: use your own broker before '
                  'connecting real machines.'),
            ),
          ),
        heading('WiFi'),
        field(_ssid, 'Network name (2.4 GHz)'),
        field(_wifiPassword, 'WiFi password', secret: true),
        heading('Panel broker account'),
        Text(
          'Give the panel its own account on the broker (see the access rules '
          'in the protocol doc), not the app\'s. Broker: ${settings.host}:'
          '${settings.tcpPort}${settings.useTls ? ' with TLS' : ''}.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        field(_username, 'Username'),
        field(_panelPassword, 'Password', secret: true),
        heading('Supply'),
        DropdownButtonFormField<int>(
          isExpanded: true,
          initialValue: wiring.meterPhases,
          decoration: const InputDecoration(
              labelText: 'Incomer meter', border: OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: 0, child: Text('None')),
            DropdownMenuItem(value: 1, child: Text('Single-phase (1 PZEM)')),
            DropdownMenuItem(value: 3, child: Text('Three-phase (3 PZEMs)')),
          ],
          onChanged: (v) =>
              setState(() => _wiring = wiring.copyWith(meterPhases: v)),
        ),
        if (wiring.meterPhases > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Give the incomer PZEMs addresses '
              '${wiring.meterAddresses.join(', ')}.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
                child: field(_under, 'Low-voltage trip (V)', number: true)),
            const SizedBox(width: 12),
            Expanded(
                child: field(_over, 'High-voltage trip (V)', number: true)),
          ],
        ),
        _pinPicker(
          label: 'Generator contact (changeover switch)',
          value: wiring.generatorPin,
          onChanged: (p) =>
              setState(() => _wiring = wiring.copyWith(generatorPin: () => p)),
        ),
        heading('Machines'),
        for (final d in devices)
          if (wiring.machines[d.id] case final w?)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        '${d.name} · ID ${d.id}'
                        '${d.phase == 'three' ? ' · three-phase' : ''}',
                        style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _pinPicker(
                            label: 'Relay',
                            value: w.relayPin,
                            allowNone: false,
                            onChanged: (p) =>
                                _setMachine(d.id, w.copyWith(relayPin: p)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _pinPicker(
                            label: 'Feedback',
                            value: w.feedbackPin,
                            onChanged: (p) => _setMachine(
                                d.id, w.copyWith(feedbackPin: () => p)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<int?>(
                            isExpanded: true,
                            initialValue: w.pzemAddress,
                            decoration: const InputDecoration(
                                labelText: 'PZEM',
                                border: OutlineInputBorder()),
                            items: [
                              const DropdownMenuItem(
                                  value: null, child: Text('None')),
                              for (var a = 1;
                                  a <= PanelWiring.maxMachineAddress;
                                  a++)
                                DropdownMenuItem(value: a, child: Text('$a')),
                            ],
                            onChanged: (a) => _setMachine(
                                d.id, w.copyWith(pzemAddress: () => a)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        const SizedBox(height: 16),
        if (problems.isNotEmpty)
          Card(
            color: UgandaTheme.tintedCard(context, UgandaTheme.danger),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final p in problems)
                    Text('• $p', style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: problems.isEmpty ? _copy : null,
          icon: const Icon(Icons.copy),
          label: const Text('Copy panel_config.h'),
        ),
        TextButton(
          onPressed: () async {
            await _save();
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Panel setup saved')));
          },
          child: const Text('Save without copying'),
        ),
        if (problems.isEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Preview'),
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: theme.colorScheme.surfaceContainerHighest,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText(
                    _config().replaceAll(
                        RegExp(r'(#define (WIFI|MQTT)_PASSWORD )".*"'),
                        r'$1"••••••"'),
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _pinPicker({
    required String label,
    required int? value,
    required ValueChanged<int?> onChanged,
    bool allowNone = true,
  }) {
    return DropdownButtonFormField<int?>(
      isExpanded: true,
      initialValue: value,
      decoration:
          InputDecoration(labelText: label, border: const OutlineInputBorder()),
      items: [
        if (allowNone) const DropdownMenuItem(value: null, child: Text('None')),
        for (final p in PanelWiring.usablePins)
          DropdownMenuItem(value: p, child: Text('GPIO $p')),
      ],
      onChanged: (p) {
        if (p != null || allowNone) onChanged(p);
      },
    );
  }
}
