import 'package:flutter/material.dart';

/// Access control settings for who may remotely operate the switch panel.
class SecurityScreen extends StatelessWidget {
  const SecurityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Security')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Require PIN for remote control'),
            subtitle: const Text('Prompt for a PIN before switching machines on/off'),
            value: false,
            onChanged: (_) {},
          ),
          const ListTile(
            leading: Icon(Icons.lock_outline),
            title: Text('Change PIN'),
          ),
        ],
      ),
    );
  }
}
