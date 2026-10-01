import 'package:flutter/material.dart';

/// Connectivity settings for the switch panel controller (MQTT broker /
/// WiFi details once hardware is paired). Placeholder pending hardware.
class NetworkScreen extends StatelessWidget {
  const NetworkScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Network')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.grey),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'No switch-panel hardware paired yet. Once a relay '
                      'controller is deployed, its MQTT broker address and '
                      'device credentials will be configured here.',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
