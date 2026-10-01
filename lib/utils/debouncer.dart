import 'dart:async';
import 'package:flutter/foundation.dart';

/// Delays an action until [delay] has passed without another call,
/// coalescing bursts of calls into a single run.
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
