import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/panel/panel_link.dart';
import '../../services/panel/panel_settings.dart';
import '../../services/panel/panel_topics.dart';
import '../../services/device_service.dart';
import '../../services/panel_service.dart';
import '../../services/security_service.dart';
import '../../widgets/common/panel_status.dart';
import '../../widgets/common/pin_dialogs.dart';
import '../../widgets/common/responsive_page.dart';
import '../../widgets/custom/uganda_theme.dart';

/// Connection settings for the switch panel: simulation, or an MQTT broker
/// shared with the panel controller.
class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  final _formKey = GlobalKey<FormState>();
  late PanelMode _mode;
  late bool _useTls;
  late final TextEditingController _host;
  late final TextEditingController _tcpPort;
  late final TextEditingController _wsPort;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _panelId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final s = panelService.settings;
    _mode = s.mode;
    _useTls = s.useTls;
    _host = TextEditingController(text: s.host)..addListener(_refresh);
    _tcpPort = TextEditingController(text: '${s.tcpPort}');
    _wsPort = TextEditingController(text: '${s.webSocketPort}');
    _username = TextEditingController(text: s.username);
    _password = TextEditingController(text: s.password);
    _panelId = TextEditingController(text: s.panelId)..addListener(_refresh);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    for (final c in [
      _host,
      _tcpPort,
      _wsPort,
      _username,
      _password,
      _panelId
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _usePublicTestBroker() {
    setState(() {
      _host.text = PanelSettings.publicTestHost;
      // EMQX public broker: MQTT 1883 / 8883 (TLS),
      // WebSocket 8083 / 8084 (TLS), path /mqtt.
      _tcpPort.text = _useTls ? '8883' : '1883';
      _wsPort.text = _useTls ? '8084' : '8083';
    });
  }

  PanelSettings _currentSettings() {
    return panelService.settings.copyWith(
      mode: _mode,
      host: _host.text.trim(),
      tcpPort: int.tryParse(_tcpPort.text.trim()),
      webSocketPort: int.tryParse(_wsPort.text.trim()),
      useTls: _useTls,
      username: _username.text.trim(),
      password: _password.text,
      panelId: _panelId.text.trim(),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    // Changing where commands go is as sensitive as switching machines on.
    if (!securityService.isUnlocked) {
      final ok = await showVerifyPinDialog(context,
          title: 'PIN required to change the panel connection');
      if (!ok) return;
    }
    setState(() => _saving = true);
    String message;
    try {
      await panelService.applySettings(_currentSettings());
      message = _mode == PanelMode.simulation
          ? 'Simulation mode on'
          : 'Connecting to ${_host.text.trim()}…';
    } catch (e) {
      message = 'Could not apply the settings: $e';
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  static String? _validatePort(String? value) {
    final port = int.tryParse(value?.trim() ?? '');
    if (port == null || port < 1 || port > 65535) return '1-65535';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final mqtt = _mode == PanelMode.mqtt;
    final topics = PanelTopics.isValidPanelId(_panelId.text.trim())
        ? PanelTopics(_panelId.text.trim())
        : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Network')),
      body: ResponsivePage(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const _StatusCard(),
              const SizedBox(height: 16),
              SegmentedButton<PanelMode>(
                segments: const [
                  ButtonSegment(
                    value: PanelMode.simulation,
                    icon: Icon(Icons.science_outlined),
                    label: Text('Simulation'),
                  ),
                  ButtonSegment(
                    value: PanelMode.mqtt,
                    icon: Icon(Icons.router_outlined),
                    label: Text('MQTT broker'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: 16),
              if (!mqtt)
                const Text(
                  'Simulation mode: switches respond instantly but do not '
                  'control real machines. Use it for demos and training.',
                ),
              if (mqtt) ..._mqttFields(context, topics),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save),
                label: Text(mqtt ? 'Save & connect' : 'Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _mqttFields(BuildContext context, PanelTopics? topics) {
    const gap = SizedBox(height: 12);
    return [
      TextFormField(
        controller: _host,
        decoration: const InputDecoration(
          labelText: 'Broker address',
          hintText: 'e.g. 192.168.1.10 or broker.example.com',
        ),
        validator: (v) =>
            (v == null || v.trim().isEmpty) ? 'Enter the broker address' : null,
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _usePublicTestBroker,
          icon: const Icon(Icons.public, size: 18),
          label: const Text('Use public test broker (demo only)'),
        ),
      ),
      if (_host.text.trim() == PanelSettings.publicTestHost)
        Card(
          color: UgandaTheme.tintedCard(context, UgandaTheme.danger),
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Anyone on the internet can read and publish to a public test '
              'broker. Use it only for demos with the panel simulator — '
              'never to control real machines.',
              style: TextStyle(color: UgandaTheme.danger),
            ),
          ),
        ),
      gap,
      Row(
        children: [
          Expanded(
            child: TextFormField(
              controller: _tcpPort,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'MQTT port',
                helperText: 'Phone / desktop app',
              ),
              validator: _validatePort,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextFormField(
              controller: _wsPort,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'WebSocket port',
                helperText: 'Web app${kIsWeb ? ' (this one)' : ''}',
              ),
              validator: _validatePort,
            ),
          ),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Use TLS encryption'),
        subtitle: const Text('Required for brokers on the internet'),
        value: _useTls,
        onChanged: (v) => setState(() => _useTls = v),
      ),
      TextFormField(
        controller: _username,
        decoration: const InputDecoration(labelText: 'Username (optional)'),
      ),
      gap,
      TextFormField(
        controller: _password,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'Password (optional)'),
      ),
      gap,
      TextFormField(
        controller: _panelId,
        decoration: const InputDecoration(
          labelText: 'Panel ID',
          helperText: 'Must match the ID configured on the panel controller',
        ),
        validator: (v) => PanelTopics.isValidPanelId(v?.trim() ?? '')
            ? null
            : '3-40 letters, digits, - or _',
      ),
      if (topics != null) ...[
        gap,
        _TopicsCard(topics: topics),
      ],
    ];
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: panelService,
      builder: (context, _) {
        final info = PanelStatusInfo.of(panelService);
        final canRetry = panelService.status == PanelLinkStatus.disconnected;
        return Card(
          color: UgandaTheme.tintedCard(context, info.color),
          child: ListTile(
            leading: Icon(info.icon, color: info.color),
            title: Text(info.label,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(info.detail),
            trailing: canRetry
                ? TextButton(
                    onPressed: panelService.reconnect,
                    child: const Text('Retry'),
                  )
                : null,
          ),
        );
      },
    );
  }
}

/// Reference for whoever programs the panel controller.
class _TopicsCard extends StatelessWidget {
  const _TopicsCard({required this.topics});

  final PanelTopics topics;

  @override
  Widget build(BuildContext context) {
    final mono = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(fontFamily: 'monospace');
    Widget row(String label, String topic) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              SelectableText(topic, style: mono),
            ],
          ),
        );

    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.developer_board),
        title: const Text('Topics for the panel controller'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        expandedAlignment: Alignment.centerLeft,
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row('Commands from the app (ON / OFF)',
              topics.command('<machine-id>')),
          row('State reported by the panel (ON / OFF, retained)',
              topics.state('<machine-id>')),
          row('Panel status (online / offline, retained, last will)',
              topics.status),
          Text('Machine IDs', style: Theme.of(context).textTheme.labelMedium),
          for (final device in deviceService.devices)
            Text('${device.id}  —  ${device.name}', style: mono),
        ],
      ),
    );
  }
}
