import 'package:flutter/material.dart';

/// Lazy load mixin for deferred initialization
mixin LazyLoadMixin<T extends StatefulWidget> on State<T> {
  bool _isLoaded = false;
  bool _isLoading = false;

  /// Override this to provide lazy loading logic
  Future<void> onLazyLoad() async {}

  /// Trigger lazy loading
  Future<void> triggerLazyLoad() async {
    if (_isLoaded || _isLoading) return;
    
    _isLoading = true;
    try {
      await onLazyLoad();
      _isLoaded = true;
    } finally {
      _isLoading = false;
    }
  }

  /// Check if content is loaded
  bool get isLoaded => _isLoaded;
  
  /// Check if content is loading
  bool get isLoading => _isLoading;

  @override
  void dispose() {
    _isLoaded = false;
    _isLoading = false;
    super.dispose();
  }
}

/// Lazy loading widget that loads content when it becomes visible
class LazyLoadWidget extends StatefulWidget {
  final Future<dynamic> Function() onLoad;
  final Widget Function(BuildContext, bool isLoading, bool hasError, dynamic data) builder;
  final Widget? loadingWidget;
  final Widget? errorWidget;
  final Duration debounceDuration;

  const LazyLoadWidget({
    super.key,
    required this.onLoad,
    required this.builder,
    this.loadingWidget,
    this.errorWidget,
    this.debounceDuration = const Duration(milliseconds: 100),
  });

  @override
  State<LazyLoadWidget> createState() => _LazyLoadWidgetState();
}

class _LazyLoadWidgetState extends State<LazyLoadWidget> {
  bool _isLoading = false;
  bool _hasError = false;
  dynamic _data;
  bool _hasTriggered = false;

  @override
  void initState() {
    super.initState();
    // Schedule load after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
    });
  }

  Future<void> _loadData() async {
    if (_hasTriggered) return;
    _hasTriggered = true;
    
    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      final data = await widget.onLoad();
      if (mounted) {
        setState(() {
          _data = data;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _hasError = true;
          _isLoading = false;
        });
      }
    }
  }

  void _retry() {
    setState(() {
      _hasError = false;
      _hasTriggered = false;
    });
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading && widget.loadingWidget != null) {
      return widget.loadingWidget!;
    }

    if (_hasError && widget.errorWidget != null) {
      return GestureDetector(
        onTap: _retry,
        child: widget.errorWidget,
      );
    }

    return widget.builder(context, _isLoading, _hasError, _data);
  }
}

/// Pagination controller for lazy loading lists
class PaginationController extends ChangeNotifier {
  int _currentPage = 0;
  int _totalPages = 0;
  bool _isLoading = false;
  bool _hasMore = true;
  final int pageSize;

  PaginationController({this.pageSize = 20});

  int get currentPage => _currentPage;
  int get totalPages => _totalPages;
  bool get isLoading => _isLoading;
  bool get hasMore => _hasMore;

  Future<List<T>> loadPage<T>({
    required Future<List<T>> Function(int page, int pageSize) loader,
  }) async {
    if (_isLoading || !_hasMore) return [];

    _isLoading = true;
    notifyListeners();

    try {
      final items = await loader(_currentPage, pageSize);
      
      if (items.length < pageSize) {
        _hasMore = false;
      } else {
        _currentPage++;
      }

      return items;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void reset() {
    _currentPage = 0;
    _totalPages = 0;
    _isLoading = false;
    _hasMore = true;
    notifyListeners();
  }

  void setTotalPages(int pages) {
    _totalPages = pages;
    _hasMore = _currentPage < pages;
    notifyListeners();
  }
}

/// Lazy loading list view with pagination
class LazyLoadListView<T> extends StatefulWidget {
  final Future<List<T>> Function(int page, int pageSize) onLoad;
  final Widget Function(BuildContext, T item, int index) itemBuilder;
  final int pageSize;
  final Widget? loadingIndicator;
  final Widget? emptyWidget;
  final EdgeInsetsGeometry? padding;
  final bool allowRefresh;

  const LazyLoadListView({
    super.key,
    required this.onLoad,
    required this.itemBuilder,
    this.pageSize = 20,
    this.loadingIndicator,
    this.emptyWidget,
    this.padding,
    this.allowRefresh = true,
  });

  @override
  State<LazyLoadListView<T>> createState() => _LazyLoadListViewState<T>();
}

class _LazyLoadListViewState<T> extends State<LazyLoadListView<T>> {
  final List<T> _items = [];
  final PaginationController _paginationController = PaginationController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    setState(() => _isLoading = true);
    await _loadMore();
    setState(() => _isLoading = false);
  }

  Future<void> _loadMore() async {
    if (_paginationController.isLoading) return;
    
    final items = await _paginationController.loadPage(loader: widget.onLoad);
    if (mounted) {
      setState(() => _items.addAll(items));
    }
  }

  Future<void> _refresh() async {
    if (!widget.allowRefresh) return;
    
    _paginationController.reset();
    _items.clear();
    await _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading && _items.isEmpty) {
      return widget.loadingIndicator ?? const Center(child: CircularProgressIndicator());
    }

    if (_items.isEmpty && !_isLoading) {
      return widget.emptyWidget ?? const Center(child: Text('No items found'));
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        padding: widget.padding,
        itemCount: _items.length + (_paginationController.hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _items.length) {
            return _buildLoadingIndicator();
          }
          return widget.itemBuilder(context, _items[index], index);
        },
      ),
    );
  }

  Widget _buildLoadingIndicator() {
    if (_paginationController.isLoading) {
      return widget.loadingIndicator ?? const Padding(
        padding: EdgeInsets.all(16.0),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return const SizedBox.shrink();
  }

  @override
  void dispose() {
    _paginationController.dispose();
    super.dispose();
  }
}

/// Lazy loading image with caching
class LazyLoadImage extends StatefulWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;

  const LazyLoadImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorWidget,
  });

  @override
  State<LazyLoadImage> createState() => _LazyLoadImageState();
}

class _LazyLoadImageState extends State<LazyLoadImage> {
  final bool _isLoading = true;
  bool _hasError = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          alignment: Alignment.center,
          children: [
            if (_isLoading)
              widget.placeholder ??
                  const CircularProgressIndicator()
            else if (_hasError)
              widget.errorWidget ??
                  const Icon(Icons.error)
            else
              Image.network(
                widget.url,
                width: widget.width ?? constraints.maxWidth,
                height: widget.height,
                fit: widget.fit,
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return widget.placeholder ?? const CircularProgressIndicator();
                },
                errorBuilder: (context, error, stackTrace) {
                  if (mounted) {
                    setState(() => _hasError = true);
                  }
                  return widget.errorWidget ?? const Icon(Icons.error);
                },
              ),
          ],
        );
      },
    );
  }
}
