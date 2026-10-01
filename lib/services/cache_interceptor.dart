import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'cache_service.dart';

/// Cache interceptor for Dio HTTP client
class DioCacheInterceptor extends Interceptor {
  final CacheService _cacheService;
  final Duration defaultDuration;

  DioCacheInterceptor({
    CacheService? cacheService,
    this.defaultDuration = const Duration(minutes: 5),
  }) : _cacheService = cacheService ?? CacheService();

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // Only cache GET requests
    if (options.method != 'GET') {
      return handler.next(options);
    }

    // Check if caching is disabled for this request
    if (options.extra['noCache'] == true) {
      return handler.next(options);
    }

    // Generate cache key from URL and query parameters
    final cacheKey = _generateCacheKey(options);

    // Try to get cached response
    final cachedData = await _cacheService.getPersistent<Map<String, dynamic>>(cacheKey);
    
    if (cachedData != null) {
      // Check if cache is still valid
      final expiresAt = DateTime.tryParse(cachedData['expiresAt'] as String? ?? '');
      if (expiresAt != null && DateTime.now().isBefore(expiresAt)) {
        // Return cached response
        final response = Response(
          requestOptions: options,
          statusCode: cachedData['statusCode'] as int? ?? 200,
          data: jsonDecode(cachedData['data'] as String),
          headers: Headers.fromMap(
            jsonDecode(cachedData['headers'] as String? ?? '{}'),
          ),
          isRedirect: false,
        );
        return handler.resolve(response);
      }
    }

    // Add cache control headers to request
    options.headers['Cache-Control'] = 'max-age=${defaultDuration.inSeconds}';
    
    // Store cache key in options for later use
    options.extra['cacheKey'] = cacheKey;

    handler.next(options);
  }

  @override
  void onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    // Only cache successful GET requests
    if (response.requestOptions.method != 'GET' || response.statusCode! < 200 || response.statusCode! >= 300) {
      return handler.next(response);
    }

    // Get cache key from options
    final cacheKey = response.requestOptions.extra['cacheKey'] as String?;
    if (cacheKey == null) {
      return handler.next(response);
    }

    // Get cache duration from response headers or use default
    final cacheControl = response.headers.value('Cache-Control') ?? '';
    final maxAge = _parseCacheControlMaxAge(cacheControl) ?? defaultDuration.inSeconds;
    final cacheDuration = Duration(seconds: maxAge);

    // Cache the response
    await _cacheService.putPersistent(
      cacheKey,
      {
        'data': jsonEncode(response.data),
        'statusCode': response.statusCode,
        'headers': jsonEncode(response.headers.map),
        'expiresAt': DateTime.now().add(cacheDuration).toIso8601String(),
      },
      expiration: cacheDuration,
    );

    handler.next(response);
  }

  String _generateCacheKey(RequestOptions options) {
    final uri = options.uri;
    return 'http_cache:${uri.path}${uri.query.isNotEmpty ? '?${uri.query}' : ''}';
  }

  int? _parseCacheControlMaxAge(String cacheControl) {
    final regex = RegExp(r'max-age=(\d+)');
    final match = regex.firstMatch(cacheControl);
    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
    return null;
  }
}

/// Cache interceptor for http package
class HttpCacheInterceptor {
  final CacheService _cacheService;
  final Duration defaultDuration;

  HttpCacheInterceptor({
    CacheService? cacheService,
    this.defaultDuration = const Duration(minutes: 5),
  }) : _cacheService = cacheService ?? CacheService();

  /// Get cached response or fetch fresh data
  Future<http.Response> get(
    Uri url, {
    Map<String, String>? headers,
    Duration? cacheDuration,
    bool forceRefresh = false,
  }) async {
    final cacheKey = 'http_cache:${url.path}${url.query.isNotEmpty ? '?${url.query}' : ''}';
    
    // Try to get cached response if not forcing refresh
    if (!forceRefresh) {
      final cachedData = await _cacheService.getPersistent<Map<String, dynamic>>(cacheKey);
      if (cachedData != null) {
        final expiresAt = DateTime.tryParse(cachedData['expiresAt'] as String? ?? '');
        if (expiresAt != null && DateTime.now().isBefore(expiresAt)) {
          return http.Response(
            cachedData['data'] as String,
            cachedData['statusCode'] as int? ?? 200,
            headers: Map<String, String>.from(
              jsonDecode(cachedData['headers'] as String? ?? '{}'),
            ),
          );
        }
      }
    }

    // Fetch fresh data
    final response = await http.get(url, headers: headers);

    // Cache successful responses
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final duration = cacheDuration ?? defaultDuration;
      await _cacheService.putPersistent(
        cacheKey,
        {
          'data': response.body,
          'statusCode': response.statusCode,
          'headers': jsonEncode(response.headers),
          'expiresAt': DateTime.now().add(duration).toIso8601String(),
        },
        expiration: duration,
      );
    }

    return response;
  }

  /// Invalidate cached response for a URL
  Future<void> invalidate(Uri url) async {
    final cacheKey = 'http_cache:${url.path}${url.query.isNotEmpty ? '?${url.query}' : ''}';
    await _cacheService.removePersistent(cacheKey);
  }

  /// Clear all HTTP cache
  Future<void> clearCache() async {
    // This would need a more sophisticated approach in production
    // For now, we'll clear all persistent cache
    await _cacheService.clearPersistent();
  }
}

/// Cache-aware HTTP client wrapper
class CachedHttpClient {
  final http.Client _client;
  final HttpCacheInterceptor _interceptor;

  CachedHttpClient({
    http.Client? client,
    CacheService? cacheService,
    Duration defaultCacheDuration = const Duration(minutes: 5),
  })  : _client = client ?? http.Client(),
        _interceptor = HttpCacheInterceptor(
          cacheService: cacheService,
          defaultDuration: defaultCacheDuration,
        );

  Future<http.Response> get(
    Uri url, {
    Map<String, String>? headers,
    Duration? cacheDuration,
    bool forceRefresh = false,
  }) {
    return _interceptor.get(
      url,
      headers: headers,
      cacheDuration: cacheDuration,
      forceRefresh: forceRefresh,
    );
  }

  Future<http.Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) {
    return _client.post(url, headers: headers, body: body);
  }

  Future<http.Response> put(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) {
    return _client.put(url, headers: headers, body: body);
  }

  Future<http.Response> delete(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) {
    return _client.delete(url, headers: headers, body: body);
  }

  void close() {
    _client.close();
  }
}