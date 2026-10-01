import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// Memory management utility class for optimizing Flutter app performance
class MemoryManager {
  static final MemoryManager _instance = MemoryManager._internal();
  factory MemoryManager() => _instance;
  MemoryManager._internal();

  // Track active subscriptions and listeners
  final List<VoidCallback> _disposables = [];
  final Map<String, dynamic> _resourceTrackers = {};
  
  // Memory warning threshold (in MB)
  static const int memoryWarningThreshold = 100;
  
  bool _isInitialized = false;
  bool _isLowMemoryMode = false;

  /// Initialize memory manager
  Future<void> init() async {
    if (_isInitialized) return;

    // Listen to memory pressure notifications
    SystemChannels.lifecycle.setMessageHandler((String? data) async {
      if (data == 'memoryPressure') {
        await _handleMemoryPressure('memory_pressure');
      }
      return null;
    });
    
    // Start memory monitoring
    _startMemoryMonitoring();
    
    _isInitialized = true;
  }

  /// Handle memory pressure from the system
  Future<void> _handleMemoryPressure(dynamic parameters) async {
    debugPrint('Memory pressure detected: $parameters');
    _isLowMemoryMode = true;
    
    // Clear caches
    await _clearAllCaches();
    
    // Trigger garbage collection hint
    SchedulerBinding.instance.addPostFrameCallback((_) {
      // Clear unused images
      imageCache.clear();
      imageCache.clearLiveImages();
    });
    
    // Notify listeners
    for (final callback in _disposables) {
      callback();
    }
    
    _isLowMemoryMode = false;
  }

  /// Start monitoring memory usage
  void _startMemoryMonitoring() {
    // Monitor memory every 30 seconds
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 30));
      if (!_isInitialized) return false;
      
      await _checkMemoryUsage();
      return true;
    });
  }

  /// Check current memory usage
  Future<void> _checkMemoryUsage() async {
    // This is a simplified check - in production you might use
    // more sophisticated memory profiling
    final currentMemory = await _getApproximateMemoryUsage();
    
    if (currentMemory > memoryWarningThreshold) {
      debugPrint('High memory usage detected: ${currentMemory}MB');
      await _handleMemoryPressure('high_memory_usage');
    }
  }

  /// Get approximate memory usage (simplified)
  Future<int> _getApproximateMemoryUsage() async {
    // This is a placeholder - actual implementation would need
    // platform-specific code to get real memory usage
    return 0;
  }

  /// Clear all caches
  Future<void> _clearAllCaches() async {
    // Clear image cache
    imageCache.clear();
    imageCache.clearLiveImages();
    
    // Clear asset bundle cache - evict requires a key, so we just notify
    // In practice, you'd want to track specific assets and evict them individually
    
    // Notify disposables
    for (final callback in _disposables) {
      callback();
    }
  }

  // ==================== RESOURCE TRACKING ====================

  /// Register a disposable resource
  void registerDisposable(VoidCallback callback, {String? id}) {
    _disposables.add(callback);
    if (id != null) {
      _resourceTrackers[id] = callback;
    }
  }

  /// Unregister a disposable resource
  void unregisterDisposable(VoidCallback callback) {
    _disposables.remove(callback);
  }

  /// Unregister by ID
  void unregisterById(String id) {
    final callback = _resourceTrackers.remove(id);
    if (callback is VoidCallback) {
      _disposables.remove(callback);
    }
  }

  /// Clear specific resource
  void clearResource(String id) {
    final callback = _resourceTrackers[id];
    if (callback is VoidCallback) {
      callback();
      _resourceTrackers.remove(id);
      _disposables.remove(callback);
    }
  }

  // ==================== IMAGE OPTIMIZATION ====================

  /// Clear image cache
  void clearImageCache() {
    imageCache.clear();
    imageCache.clearLiveImages();
  }

  /// Evict specific image from cache
  void evictImage(String key) {
    imageCache.evict(key);
  }

  /// Get image cache statistics
  Map<String, int> getImageCacheStats() {
    return {
      'pending': imageCache.pendingImageCount,
      'live': imageCache.liveImageCount,
    };
  }

  // ==================== ASSET OPTIMIZATION ====================

  /// Evict asset from cache
  Future<void> evictAsset(String key) async {
    rootBundle.evict(key);
  }

  // ==================== WIDGET OPTIMIZATION ====================

  /// Create a const-aware widget that minimizes rebuilds
  static Widget optimizeWidget(Widget child, {List<Object?>? dependencies}) {
    return RepaintBoundary(
      child: child,
    );
  }

  /// Wrap widget with automatic keep alive for lists
  static Widget keepAlive(Widget child) {
    return KeepAliveWrapper(child: child);
  }

  // ==================== MEMORY MODE ====================

  /// Check if app is in low memory mode
  bool get isLowMemoryMode => _isLowMemoryMode;

  /// Get memory manager status
  Map<String, dynamic> getStatus() {
    return {
      'is_initialized': _isInitialized,
      'is_low_memory_mode': _isLowMemoryMode,
      'tracked_resources': _resourceTrackers.length,
      'disposables_count': _disposables.length,
    };
  }

  /// Dispose all resources
  Future<void> dispose() async {
    _isInitialized = false;
    
    // Call all disposables
    for (final callback in _disposables) {
      callback();
    }
    
    _disposables.clear();
    _resourceTrackers.clear();
    
    // Clear caches
    await _clearAllCaches();
  }
}

/// Widget wrapper for keep alive functionality
class KeepAliveWrapper extends StatefulWidget {
  final Widget child;

  const KeepAliveWrapper({
    super.key,
    required this.child,
  });

  @override
  State<KeepAliveWrapper> createState() => _KeepAliveWrapperState();
}

class _KeepAliveWrapperState extends State<KeepAliveWrapper> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// Debouncer for expensive operations
class Debouncer {
  final Duration delay;
  Timer? _timer;

  Debouncer({required this.delay});

  void call(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void dispose() {
    _timer?.cancel();
  }
}

/// Throttler for limiting function calls
class Throttler {
  final Duration interval;
  Timer? _timer;
  bool _isThrottled = false;

  Throttler({required this.interval});

  void call(VoidCallback action) {
    if (_isThrottled) return;
    
    action();
    _isThrottled = true;
    
    _timer = Timer(interval, () {
      _isThrottled = false;
    });
  }

  void dispose() {
    _timer?.cancel();
  }
}

// Export singleton instance
final memoryManager = MemoryManager();