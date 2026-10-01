import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';

import 'bloc/connectivity_bloc.dart';
import 'services/alert_service.dart';
import 'services/cache_service.dart';
import 'services/device_service.dart';
import 'services/tariff_service.dart';
import 'utils/memory_manager.dart';
import 'widgets/custom/uganda_theme.dart';

// Import screens
import 'screens/main_shell.dart';
import 'screens/notifications/alerts_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/devices/add_device_screen.dart';
import 'screens/cache_test_screen.dart'; // ADDED

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize services with error handling
  await _initializeServices();
  
  runApp(const MyApp());
}

Future<void> _initializeServices() async {
  // Initialize cache service (optional - app can work without it)
  try {
    await cacheService.init();
  } catch (e, stackTrace) {
    debugPrint('Cache service initialization failed: $e');
    debugPrint('Stack trace: $stackTrace');
    // Continue anyway - app can work without cache
  }
  
  // Initialize memory manager (optional)
  try {
    await memoryManager.init();
  } catch (e, stackTrace) {
    debugPrint('Memory manager initialization failed: $e');
    debugPrint('Stack trace: $stackTrace');
    // Continue anyway
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

  // Initialize alerts and check tariff health (stale rate, cost threshold)
  try {
    await alertService.init();
    await alertService.checkTariffHealth();
  } catch (e, stackTrace) {
    debugPrint('Alert service initialization failed: $e');
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
        BlocProvider(create: (_) => ConnectivityBloc()),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'SMART-AUTOMIX',
        theme: UgandaTheme.themeData,
        darkTheme: UgandaTheme.darkThemeData,
        themeMode: ThemeMode.system,
        initialRoute: '/',
        onGenerateRoute: _generateRoute,
        builder: (context, child) {
          return _PerformanceOptimizer(
            child: child ?? const SizedBox(),
          );
        },
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
      case '/settings':
        return _createRoute(const SettingsScreen());
      case '/add-device':
        return _createRoute(const AddDeviceScreen());
      case '/cache-test':          // ADDED
        return _createRoute(const CacheTestScreen());
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

/// Performance optimizer widget that wraps the app
class _PerformanceOptimizer extends StatefulWidget {
  const _PerformanceOptimizer({required this.child}) : super(key: null);

  final Widget child;

  @override
  State<_PerformanceOptimizer> createState() => _PerformanceOptimizerState();
}

class _PerformanceOptimizerState extends State<_PerformanceOptimizer> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
        // App is in background - clear memory cache
        cacheService.clearMemory();
        break;
      case AppLifecycleState.resumed:
        // App is foreground - could reload critical data
        break;
      case AppLifecycleState.detached:
        // App is being terminated - cleanup
        cacheService.dispose();
        memoryManager.dispose();
        break;
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
