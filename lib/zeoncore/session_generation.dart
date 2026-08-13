import 'dart:async';

typedef StaleGenerationCallback = void Function(int staleGeneration, int currentGeneration, String source);

enum SessionCompletionDisposition { current, stale }

/// Monotonic session gate shared by Flutter lifecycle and stream adapters.
class SessionGenerationGate {
  SessionGenerationGate({int? seed, this.onStale}) : _current = seed ?? DateTime.now().microsecondsSinceEpoch;

  final StaleGenerationCallback? onStale;
  int _current;

  int get current => _current;

  int next() => ++_current;

  /// Synchronizes with an authoritative platform operation without ever
  /// moving backwards. The following locally allocated operation is therefore
  /// strictly newer than an externally initiated terminal generation.
  int advanceTo(int generation) {
    if (generation > _current) {
      _current = generation;
    }
    return _current;
  }

  bool isCurrent(int generation, {required String source}) {
    if (generation == _current) return true;
    onStale?.call(generation, _current, source);
    return false;
  }

  SessionCompletionDisposition classifyCompletion(int generation, {required String source}) {
    return isCurrent(generation, source: source)
        ? SessionCompletionDisposition.current
        : SessionCompletionDisposition.stale;
  }
}

/// Serializes lifecycle bodies without using timing assumptions. Generations
/// are still allocated at request time; a queued body must apply its own stale
/// gate before touching state or resources.
class SerialLifecycleQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> enqueue<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.catchError((_) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
