import 'package:flutter/material.dart';
import '../services/cache_service.dart';

class CacheTestScreen extends StatefulWidget {
  const CacheTestScreen({super.key});

  @override
  State<CacheTestScreen> createState() => _CacheTestScreenState();
}

class _CacheTestScreenState extends State<CacheTestScreen> {
  final CacheService _cache = cacheService;
  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _valueController = TextEditingController();
  String _output = '';

  @override
  void initState() {
    super.initState();
    _initializeCache();
  }

  Future<void> _initializeCache() async {
    await _cache.init();
    // Note: _persistentCacheAvailable is private – we use getStats() instead
    setState(() {
      _output = 'Cache initialized. Ready for testing.';
    });
  }

  Future<void> _testMemoryPutGet() async {
    final key = _keyController.text.trim();
    final value = _valueController.text.trim();
    if (key.isEmpty || value.isEmpty) {
      setState(() => _output = 'Please enter both key and value');
      return;
    }

    _cache.putMemory(key, value);
    final retrieved = _cache.getMemory<String>(key);
    setState(() {
      _output = 'Memory Cache Test\n'
          'Put: "$value" at key "$key"\n'
          'Retrieved: "$retrieved"\n'
          'Success: ${retrieved == value}';
    });
  }

  Future<void> _testExpiration() async {
    const key = 'exp_test';
    // Put with very short expiration (2 seconds)
    _cache.putMemory(key, 'This will expire quickly', expiration: const Duration(seconds: 2));
    setState(() => _output = 'Put value with 2-second expiration. Wait 3 seconds...');
    
    await Future.delayed(const Duration(seconds: 3));
    final retrieved = _cache.getMemory<String>(key);
    setState(() {
      _output = 'Expiration Test\n'
          'After 3 seconds, value is ${retrieved == null ? "null (expired)" : "still: $retrieved"}\n'
          'Expiration works: ${retrieved == null}';
    });
  }

  Future<void> _testFileCache() async {
    const testUrl = 'https://picsum.photos/200/300'; // sample image
    setState(() => _output = 'Downloading & caching file...');
    
    try {
      final file = await _cache.getFileFromCache(testUrl);
      if (file != null) {
        setState(() {
          _output = 'File cache test successful!\n'
              'File path: ${file.path}\n'
              'Exists: ${file.existsSync()}\n'
              'Size: ${file.lengthSync()} bytes';
        });
      } else {
        setState(() => _output = 'File cache test failed - file is null');
      }
    } catch (e) {
      setState(() => _output = 'File cache error: $e');
    }
  }

  Future<void> _testGetOrFetch() async {
    final key = 'fetch_test_${DateTime.now().millisecondsSinceEpoch}';
    int fetchCount = 0;
    
    Future<String?> mockFetch() async {
      fetchCount++;
      await Future.delayed(const Duration(milliseconds: 100));
      return 'Fetched data #$fetchCount';
    }
    
    // First call - should fetch
    final result1 = await _cache.getOrFetch(key: key, fetchFunction: mockFetch);
    // Second call - should come from cache
    final result2 = await _cache.getOrFetch(key: key, fetchFunction: mockFetch);
    
    setState(() {
      _output = 'Smart Cache Test (getOrFetch)\n'
          'First call: $result1\n'
          'Second call: $result2\n'
          'Fetch function called $fetchCount times (should be 1)\n'
          'Caching works: ${fetchCount == 1}';
    });
  }

  Future<void> _showStats() async {
    final stats = await _cache.getStats();
    setState(() {
      _output = 'Cache Statistics:\n'
          '${stats.entries.map((e) => '${e.key}: ${e.value}').join('\n')}';
    });
  }

  Future<void> _clearAll() async {
    await _cache.clearAll();
    setState(() => _output = 'All caches cleared.');
  }

  @override
  void dispose() {
    _keyController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cache Service Test')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _keyController,
              decoration: const InputDecoration(labelText: 'Key'),
            ),
            TextField(
              controller: _valueController,
              decoration: const InputDecoration(labelText: 'Value'),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(onPressed: _testMemoryPutGet, child: const Text('Memory Put/Get')),
                ElevatedButton(onPressed: _testExpiration, child: const Text('Test Expiration')),
                ElevatedButton(onPressed: _testFileCache, child: const Text('Test File Cache')),
                ElevatedButton(onPressed: _testGetOrFetch, child: const Text('Test getOrFetch')),
                ElevatedButton(onPressed: _showStats, child: const Text('Show Stats')),
                ElevatedButton(onPressed: _clearAll, child: const Text('Clear All')),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  _output,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}