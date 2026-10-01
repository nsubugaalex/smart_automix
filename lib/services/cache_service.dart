import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
//import 'package:path_provider/path_provider.dart';
import 'dart:io';

/// Cache configuration constants
class CacheConfig {
  static const Duration defaultExpiration = Duration(hours: 1);
  static const Duration shortExpiration = Duration(minutes: 15);
  static const Duration longExpiration = Duration(days: 1);
  static const int maxCacheSize = 100 * 1024 * 1024; // 100MB
}

/// Cache entry with metadata
class CacheEntry<T> {
  final T data;
  final DateTime createdAt;
  final Duration expiration;

  CacheEntry({
    required this.data,
    required this.expiration,
  }) : createdAt = DateTime.now();

  bool get isExpired => DateTime.now().isAfter(createdAt.add(expiration));
  
  T? get dataIfValid => isExpired ? null : data;
}

/// Centralized cache service for the application
/// On web, persistent cache is not available, only memory cache is used
class CacheService {
  static final CacheService _instance = CacheService._internal();
  factory CacheService() => _instance;
  CacheService._internal() {
    // Run cleanup once when the service is created
    _cleanupExpiredEntries();
  }

  // In-memory cache for frequently accessed data
  final Map<String, CacheEntry> _memoryCache = {};
  
  // Hive box for persistent cache (not used on web)
  // dynamic _persistentCache;
  
  // File cache manager for images and large files
  late CacheManager _fileCacheManager;
  
  bool _isInitialized = false;
  bool _persistentCacheAvailable = false;

  /// Initialize the cache service
  Future<void> init() async {
    if (_isInitialized) return;

    try {
      // On web, we only use memory cache
      if (kIsWeb) {
        debugPrint('Running on web - using memory cache only');
        _persistentCacheAvailable = false;
      } else {
        // Initialize Hive for persistent cache on mobile/desktop
        try {
          // Commented out Hive initialization to avoid web issues
          // final appDocDir = await getApplicationDocumentsDirectory();
          // Hive.init(appDocDir.path);
          // _persistentCache = await Hive.openBox('smart_automix_cache');
          _persistentCacheAvailable = false; // Disabled for stability
        } catch (e) {
          debugPrint('Hive initialization failed: $e');
          _persistentCacheAvailable = false;
        }
      }
      
      // Initialize file cache manager
      try {
        _fileCacheManager = CacheManager(
          Config(
            'smart_automix_files',
            stalePeriod: const Duration(days: 7),
            maxNrOfCacheObjects: 100,
            repo: JsonCacheInfoRepository(databaseName: 'smart_automix_files'),
            fileService: HttpFileService(),
          ),
        );
      } catch (e) {
        debugPrint('File cache manager initialization failed: $e');
      }
      
      _isInitialized = true;
    } catch (e) {
      // Log error but don't throw - app can work without cache
      debugPrint('Cache initialization error: $e');
      _isInitialized = true; // Mark as initialized to prevent repeated attempts
    }
  }

  // ==================== MEMORY CACHE ====================

  /// Store data in memory cache
  void putMemory<T>(String key, T data, {Duration? expiration}) {
    if (!_isInitialized) return;
    
    _memoryCache[key] = CacheEntry(
      data: data,
      expiration: expiration ?? CacheConfig.defaultExpiration,
    );
  }

  /// Retrieve data from memory cache
  T? getMemory<T>(String key) {
    if (!_isInitialized) return null;
    
    final entry = _memoryCache[key];
    if (entry == null) return null;
    
    return entry.dataIfValid as T?;
  }

  /// Check if memory cache contains key
  bool hasMemory(String key) {
    if (!_isInitialized) return false;
    
    final entry = _memoryCache[key];
    return entry != null && !entry.isExpired;
  }

  /// Remove item from memory cache
  void removeMemory(String key) {
    _memoryCache.remove(key);
  }

  /// Clear all memory cache
  void clearMemory() {
    _memoryCache.clear();
  }

  // ==================== PERSISTENT CACHE ====================
  // Note: Persistent cache is disabled on web for stability

  /// Store data in persistent cache (no-op on web)
  Future<void> putPersistent<T>(String key, T data, {Duration? expiration}) async {
    if (!_isInitialized || !_persistentCacheAvailable) return;
    
    // Persistent cache is currently disabled
    // Store in memory cache instead
    putMemory(key, data, expiration: expiration);
  }

  /// Retrieve data from persistent cache (falls back to memory on web)
  Future<T?> getPersistent<T>(String key) async {
    if (!_isInitialized) return null;
    
    if (!_persistentCacheAvailable) {
      // Fall back to memory cache
      return getMemory<T>(key);
    }
    
    // Persistent cache is currently disabled
    return getMemory<T>(key);
  }

  /// Check if persistent cache contains valid key
  Future<bool> hasPersistent(String key) async {
    if (!_isInitialized) return false;
    
    if (!_persistentCacheAvailable) {
      return hasMemory(key);
    }
    
    final data = await getPersistent(key);
    return data != null;
  }

  /// Remove item from persistent cache
  Future<void> removePersistent(String key) async {
    if (!_isInitialized) return;
    
    if (_persistentCacheAvailable) {
      // _persistentCache.delete(key);
    }
    removeMemory(key);
  }

  /// Clear all persistent cache
  Future<void> clearPersistent() async {
    if (!_isInitialized) return;
    
    if (_persistentCacheAvailable) {
      // _persistentCache.clear();
    }
    clearMemory();
  }

  // ==================== FILE CACHE ====================

  /// Get file from cache or download
  Future<File?> getFileFromCache(String url) async {
    if (!_isInitialized) return null;
    
    final fileInfo = await _fileCacheManager.getFileFromCache(url);
    if (fileInfo != null) {
      return fileInfo.file;
    }
    
    // Download and cache
    final file = await _fileCacheManager.downloadFile(url);
    return file.file;
  }

  /// Get file stream from cache
  Stream<FileResponse> getFileStream(String url) {
    if (!_isInitialized) return const Stream.empty();
    return _fileCacheManager.getFileStream(url);
  }

  /// Remove file from cache
  Future<void> removeFile(String url) async {
    if (!_isInitialized) return;
    await _fileCacheManager.removeFile(url);
  }

  /// Clear all file cache
  Future<void> clearFileCache() async {
    if (!_isInitialized) return;
    await _fileCacheManager.emptyCache();
  }

  // ==================== SMART CACHE ====================

  /// Get data with memory cache first, then persistent, then fetch
  Future<T?> getOrFetch<T>({
    required String key,
    required Future<T?> Function() fetchFunction,
    Duration? expiration,
    bool useMemoryCache = true,
  }) async {
    if (!_isInitialized) return await fetchFunction();
    
    // Try memory cache first
    if (useMemoryCache) {
      final memoryData = getMemory<T>(key);
      if (memoryData != null) return memoryData;
    }
    
    // Try persistent cache
    final persistentData = await getPersistent<T>(key);
    if (persistentData != null) {
      // Put back in memory cache for faster access
      if (useMemoryCache) {
        putMemory(key, persistentData, expiration: expiration);
      }
      return persistentData;
    }
    
    // Fetch fresh data
    final data = await fetchFunction();
    if (data != null) {
      // Store in both caches
      putMemory(key, data, expiration: expiration);
      await putPersistent(key, data, expiration: expiration);
    }
    
    return data;
  }

  /// Invalidate cache entry
  Future<void> invalidate(String key) async {
    removeMemory(key);
    await removePersistent(key);
  }

  /// Clear all caches
  Future<void> clearAll() async {
    clearMemory();
    await clearPersistent();
    await clearFileCache();
  }

  // ==================== MAINTENANCE ====================

  /// Clean up expired entries (synchronous because async part is commented)
  void _cleanupExpiredEntries() {
    // Clean memory cache
    _memoryCache.removeWhere((key, entry) => entry.isExpired);

    // Persistent cache cleanup is disabled (commented out)
    // if (_persistentCacheAvailable) {
    //   final keys = _persistentCache.keys.toList();
    //   for (final key in keys) {
    //     final jsonData = _persistentCache.get(key);
    //     if (jsonData == null) continue;
    //     
    //     try {
    //       final decoded = jsonDecode(jsonData as String) as Map<String, dynamic>;
    //       final createdAt = DateTime.parse(decoded['createdAt'] as String);
    //       final expiration = Duration(seconds: decoded['expiration'] as int);
    //       
    //       if (DateTime.now().isAfter(createdAt.add(expiration))) {
    //         await _persistentCache.delete(key);
    //       }
    //     } catch (e) {
    //       await _persistentCache.delete(key);
    //     }
    //   }
    // }
  }

  /// Get cache statistics
  Future<Map<String, dynamic>> getStats() async {
    if (!_isInitialized) return {};
    
    final memorySize = _memoryCache.length;
    const persistentSize = 0; // _persistentCacheAvailable ? _persistentCache.length : 0;
    
    // Calculate approximate memory usage
    int memoryBytes = 0;
    for (final entry in _memoryCache.values) {
      // Rough estimation
      memoryBytes += entry.data.toString().length * 2;
    }
    
    return {
      'memory_cache_entries': memorySize,
      'memory_cache_size_bytes': memoryBytes,
      'persistent_cache_entries': persistentSize,
      'is_initialized': _isInitialized,
      'persistent_cache_available': _persistentCacheAvailable,
      'is_web': kIsWeb,
    };
  }

  /// Dispose resources
  Future<void> dispose() async {
    // if (_persistentCacheAvailable) {
    //   await _persistentCache.close();
    // }
    _memoryCache.clear();
    _isInitialized = false;
  }
}

// Export singleton instance
final cacheService = CacheService();