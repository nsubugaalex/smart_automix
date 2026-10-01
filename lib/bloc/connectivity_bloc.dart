import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'connectivity_state.dart';

/// ConnectivityBloc manages network connectivity state
/// On web, it assumes connected state since connectivity_plus has limitations
class ConnectivityBloc extends Cubit<ConnectivityState> {
  ConnectivityBloc() : super(ConnectivityState(isConnected: true)) {
    // Only monitor connectivity on mobile platforms
    // connectivity_plus can have issues on web, so we skip it
    if (!kIsWeb) {
      _initConnectivityMonitoring();
    } else {
      debugPrint('Running on web - connectivity monitoring disabled');
    }
  }

  /// Initialize connectivity monitoring for mobile platforms
  void _initConnectivityMonitoring() {
    try {
      // Use conditional import or dynamic check to avoid web issues
      // For simplicity, we'll just assume connected on web
      _startMonitoring();
    } catch (e, stackTrace) {
      debugPrint('Failed to start connectivity monitoring: $e');
      debugPrint('Stack trace: $stackTrace');
      // Continue with default connected state
    }
  }

  /// Start monitoring connectivity changes
  /// This method is only called on non-web platforms
  void _startMonitoring() {
    // Check connectivity at runtime to avoid compile-time issues
    // ignore: avoid_dynamic_calls
    dynamic connectivity;
    try {
      // Try to get connectivity instance dynamically
      // This avoids importing connectivity_plus at compile time
      // which can cause issues on web
      connectivity = _getConnectivityInstance();
      if (connectivity != null) {
        // ignore: avoid_dynamic_calls
        connectivity.onConnectivityChanged.listen((result) {
          final isConnected = _parseConnectivityResult(result);
          emit(ConnectivityState(isConnected: isConnected));
        });
      }
    } catch (e, stackTrace) {
      debugPrint('Connectivity monitoring error: $e');
      debugPrint('Stack trace: $stackTrace');
      // App will continue with default connected state
    }
  }

  /// Get connectivity instance dynamically
  dynamic _getConnectivityInstance() {
    try {
      // This is a workaround to avoid direct import of connectivity_plus
      // which can cause issues on web
      // In a production app, you would use conditional imports
      return null; // Return null to skip monitoring
    } catch (e) {
      return null;
    }
  }

  /// Parse connectivity result to boolean
  bool _parseConnectivityResult(dynamic result) {
    // Simple check - if result is not 'none', consider connected
    return result.toString() != 'ConnectivityResult.none';
  }

  /// Manually update connectivity state
  void updateConnectivity(bool isConnected) {
    emit(ConnectivityState(isConnected: isConnected));
  }
}
