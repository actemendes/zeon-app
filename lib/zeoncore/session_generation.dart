typedef StaleGenerationCallback = void Function(int staleGeneration, int currentGeneration, String source);

/// Monotonic session gate shared by Flutter lifecycle and stream adapters.
class SessionGenerationGate {
  SessionGenerationGate({int? seed, this.onStale}) : _current = seed ?? DateTime.now().microsecondsSinceEpoch;

  final StaleGenerationCallback? onStale;
  int _current;

  int get current => _current;

  int next() => ++_current;

  bool isCurrent(int generation, {required String source}) {
    if (generation == _current) return true;
    onStale?.call(generation, _current, source);
    return false;
  }
}
