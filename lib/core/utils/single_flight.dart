import 'dart:async';

/// Coalesces concurrent calls so all callers await the same operation.
///
/// A new operation may start after the previous one completes. This is useful
/// for lifecycle work that must be retried later, but must never run twice at
/// the same time.
class SingleFlight<T> {
  Future<T>? _inFlight;

  bool get isRunning => _inFlight != null;

  Future<T> run(FutureOr<T> Function() operation) {
    final pending = _inFlight;
    if (pending != null) return pending;

    late final Future<T> future;
    future = Future<T>.sync(operation).whenComplete(() {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    });
    _inFlight = future;
    return future;
  }
}
