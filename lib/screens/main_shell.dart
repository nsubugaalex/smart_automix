import 'dart:async';

import 'package:flutter/material.dart';
import '../services/alert_service.dart';
import '../services/device_service.dart';
import '../widgets/common/panel_status.dart';
import '../widgets/custom/uganda_theme.dart';
import 'dashboard/control_panel_screen.dart';
import 'dashboard/energy_monitor_screen.dart';
import 'dashboard/home_screen.dart';
import 'settings/tariff_screen.dart';

/// Persistent app shell: a single Scaffold that owns the app bar, the
/// primary bottom navigation (Dashboard / Control / Energy / Tariff), and
/// a drawer for secondary destinations (Alerts, Settings, About). Tab
/// bodies are kept alive in an [IndexedStack] so switching tabs doesn't
/// re-run each screen's init logic.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  late final StreamSubscription<CommandFailure> _failuresSub;

  @override
  void initState() {
    super.initState();
    // Tell the operator straight away when a switch didn't take effect
    // (the alert is also recorded in the Alerts screen).
    _failuresSub = deviceService.commandFailures.listen((failure) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: UgandaTheme.danger,
        content: Text('${failure.machineName}: ${failure.reason}'),
      ));
    });
  }

  @override
  void dispose() {
    _failuresSub.cancel();
    super.dispose();
  }

  static const _titles = [
    'SMART-AUTOMIX',
    'Control Panel',
    'Energy Monitor',
    'UEDCL Tariff',
  ];

  static const _pages = [
    DashboardBody(),
    ControlPanelBody(),
    EnergyMonitorBody(),
    TariffBody(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        actions: [
          PanelStatusIcon(
            onTap: () => Navigator.pushNamed(context, '/network'),
          ),
          AnimatedBuilder(
            animation: alertService,
            builder: (context, _) {
              final unread = alertService.unreadCount;
              return IconButton(
                icon: Badge(
                  isLabelVisible: unread > 0,
                  label: Text('$unread'),
                  child: const Icon(Icons.notifications),
                ),
                onPressed: () => Navigator.pushNamed(context, '/alerts'),
              );
            },
          ),
        ],
      ),
      drawer: _buildDrawer(context),
      body: IndexedStack(index: _index, children: _pages),
      floatingActionButton: _index == 0 || _index == 1
          ? FloatingActionButton.extended(
              onPressed: () => Navigator.pushNamed(context, '/add-device'),
              icon: const Icon(Icons.add),
              label: const Text('Add Machine'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.electrical_services_outlined),
            selectedIcon: Icon(Icons.electrical_services),
            label: 'Control',
          ),
          NavigationDestination(
            icon: Icon(Icons.energy_savings_leaf_outlined),
            selectedIcon: Icon(Icons.energy_savings_leaf),
            label: 'Energy',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'Tariff',
          ),
        ],
      ),
    );
  }

  Widget _buildDrawer(BuildContext context) {
    return Drawer(
      child: ListView(
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: UgandaTheme.black),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.electrical_services,
                    color: UgandaTheme.yellow, size: 36),
                SizedBox(height: 8),
                Text(
                  'SMART-AUTOMIX',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Industrial Switch & Electricity Management',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
          AnimatedBuilder(
            animation: alertService,
            builder: (context, _) {
              final unread = alertService.unreadCount;
              return ListTile(
                leading: Badge(
                  isLabelVisible: unread > 0,
                  label: Text('$unread'),
                  child: const Icon(Icons.notifications_outlined),
                ),
                title: const Text('Alerts'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.pushNamed(context, '/alerts');
                },
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.build_outlined),
            title: const Text('Maintenance'),
            onTap: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/maintenance');
            },
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Activity'),
            onTap: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/activity');
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/settings');
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            onTap: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/about');
            },
          ),
        ],
      ),
    );
  }
}
