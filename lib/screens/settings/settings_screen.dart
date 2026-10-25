import 'package:flutter/material.dart';
import 'network_screen.dart';
import 'panel_setup_screen.dart';
import 'security_screen.dart';
import 'profile_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.wifi),
            title: const Text('Network'),
            subtitle: const Text('Switch panel connectivity'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const NetworkScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.developer_board),
            title: const Text('Panel setup'),
            subtitle: const Text('Wiring and firmware configuration'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const PanelSetupScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.security),
            title: const Text('Security'),
            subtitle: const Text('PIN, access control'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const SecurityScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.person),
            title: const Text('Profile'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const ProfileScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
