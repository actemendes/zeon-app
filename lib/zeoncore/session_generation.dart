import 'dart:async';

typedef StaleGenerationCallback = void Function(int staleGeneration, int currentGeneration, String source);

enum SessionCompletionDisposition { current, stale }

/// Monotonic session gate shared by Flutter lifecycle and stream adapters.
class SessionGenerationGate {
  SessionGenerationGate({int? seed, this.onStale})
    : _current = seed ?? 0,
      _highWatermark = seed ?? 0,
      _allocateFromWallClock = seed == null;

  final StaleGenerationCallback? onStale;
  final bool _allocateFromWallClock;
  int _current;
  int _highWatermark;

  int get current => _current;

  int next() {
    final incremented = (_current > _highWatermark ? _current : _highWatermark) + 1;
    // A freshly relaunched host starts at zero so it can adopt the generation
    // of a tunnel that survived the previous process. The first local intent
    // then jumps to a wall-clock-sized value, preserving monotonic ownership
    // across launches and fencing every callback from the adopted session.
    if (_allocateFromWallClock) {
      final now = DateTime.now().microsecondsSinceEpoch;
      _current = now > incremented ? now : incremented;
    } else {
      _current = incremented;
    }
    if (_current > _highWatermark) _highWatermark = _current;
    return _current;
  }

  /// Synchronizes with an authoritative platform operation without ever
  /// moving backwards. The following locally allocated operation is therefore
  /// strictly newer than an externally initiated terminal generation.
  int advanceTo(int generation) {
    if (generation > _current) {
      _current = generation;
    }
    if (generation > _highWatermark) _highWatermark = generation;
    return _current;
  }

  /// Releases an optional/provisional owner only if it still owns the gate.
  /// The allocation high-watermark is retained, so a cancelled generation is
  /// never reused even when the authoritative platform owner is older.
  bool replaceCurrentIf(int expected, int replacement) {
    if (_current != expected || replacement < 0) return false;
    _current = replacement;
    if (expected > _highWatermark) _highWatermark = expected;
    if (replacement > _highWatermark) _highWatermark = replacement;
    return true;
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
