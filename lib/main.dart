import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/activity_log.dart';
import 'services/alert_service.dart';
import 'services/device_service.dart';
import 'services/maintenance_service.dart';
import 'services/prepaid_service.dart';
import 'services/operator_profile.dart';
import 'services/panel_service.dart';
import 'services/security_service.dart';
import 'services/tariff_service.dart';
import 'widgets/custom/uganda_theme.dart';

// Import screens
import 'screens/main_shell.dart';
import 'screens/notifications/activity_screen.dart';
import 'screens/notifications/alerts_screen.dart';
import 'screens/settings/network_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/devices/add_device_screen.dart';
import 'screens/maintenance/maintenance_screen.dart';
import 'screens/prepaid/prepaid_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize services with error handling
  await _initializeServices();

  runApp(const MyApp());
}

Future<void> _initializeServices() async {
  // Who is using this phone (sent with commands for the activity log).
  try {
    await operatorProfile.init();
  } catch (e, stackTrace) {
    debugPrint('Operator profile initialization failed: $e');
    debugPrint('Stack trace: $stackTrace');
  }

  // Load the switch-panel connection settings and start connecting in the
  // background (simulation mode unless an MQTT broker is configured).
  try {
    await panelService.init();
  } catch (e, stackTrace) {
    debugPrint('Panel service initialization failed: $e');
    debugPrint('Stack trace: $stackTrace');
  }

  // Initialize device service (optional - will use empty list if fails)
  try {
    await deviceService.init();
  } catch (e, stackTrace) {
    debugPrint('Device service initialization failed: $e');
    debugPrint('Stack trace: $stackTrace');
    // Continue anyway - will use empty device list
  }

  // Initialize tariff service (optional - falls back to category defaults)
  try {
    await tariffService.init();
  } catch (e, stackTrace) {
    debugPrint('Tariff service initialization failed: $e');
    debugPrint('Stack trace: $stackTrace');
  }

  // Load the operator PIN settings. If secure storage is unavailable the
  // PIN stays off rather than locking the operator out of the panel.
  try {
    await securityService.init();
  } catch (e, stackTrace) {
    debugPrint('Security service initialization failed: $e');
    debugPrint('Stack trace: $stackTrace');
  }

  // Running hours and maintenance tasks, and prepaid credit (before
  // alerts, which watch them).
  try {
    await prepaidService.init();
  } catch (e, stackTrace) {
    debugPrint('Prepaid credit initialization failed: $e');
    debugPrint('Stack trace: $stackTrace');
  }
  try {
    await maintenanceService.init();
  } catch (e, stackTrace) {
    debugPrint('Maintenance initialization failed: $e');
    debugPrint('Stack trace: $stackTrace');
  }

  // Initialize alerts and check tariff health (stale rate, cost threshold)
  try {
    await alertService.init();
    await alertService.checkTariffHealth();
    await alertService.checkMaintenance();
    await alertService.checkPrepaid();
  } catch (e, stackTrace) {
    debugPrint('Alert service initialization failed: $e');
    debugPrint('Stack trace: $stackTrace');
  }

  try {
    await activityLog.init();
  } catch (e, stackTrace) {
    debugPrint('Activity log initialization failed: $e');
    debugPrint('Stack trace: $stackTrace');
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: deviceService),
        ChangeNotifierProvider.value(value: tariffService),
        ChangeNotifierProvider.value(value: alertService),
        ChangeNotifierProvider.value(value: panelService),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'SMART-AUTOMIX',
        theme: UgandaTheme.themeData,
        darkTheme: UgandaTheme.darkThemeData,
        themeMode: ThemeMode.system,
        initialRoute: '/',
        onGenerateRoute: _generateRoute,
      ),
    );
  }

  /// Lazy route generation for better performance
  Route<dynamic>? _generateRoute(RouteSettings settings) {
    switch (settings.name) {
      case '/':
        return _createRoute(const MainShell());
      case '/alerts':
        return _createRoute(const AlertsScreen());
      case '/activity':
        return _createRoute(const ActivityScreen());
      case '/maintenance':
        return _createRoute(const MaintenanceScreen());
      case '/prepaid':
        return _createRoute(const PrepaidScreen());
      case '/settings':
        return _createRoute(const SettingsScreen());
      case '/network':
        return _createRoute(const NetworkScreen());
      case '/add-device':
        return _createRoute(const AddDeviceScreen());
      case '/about':
        return _createRoute(_buildAboutScreen());
      default:
        return null;
    }
  }

  /// Build a simple about screen
  Widget _buildAboutScreen() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('About'),
      ),
      body: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.electrical_services, size: 64, color: UgandaTheme.red),
            SizedBox(height: 16),
            Text(
              'SMART-AUTOMIX',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              'Version 1.0.0',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
            SizedBox(height: 8),
            Text(
              'Small-Scale Industrial Switch & Electricity Management (Uganda)',
              style: TextStyle(fontSize: 14, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Custom route with fade transition for smoother navigation
  Route<T> _createRoute<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: animation,
          child: child,
        );
      },
      transitionDuration: const Duration(milliseconds: 200),
    );
  }
}
