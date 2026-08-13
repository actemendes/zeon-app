import 'dart:async';

typedef DesiredStateApplier<T> = Future<void> Function(T desiredState, int generation);

/// Coalesces state requests while guaranteeing that the latest request is
/// applied before the returned future completes.
///
/// Unlike a plain single-flight, a request received while [apply] is running is
/// not lost: the reconciliation loop observes the new generation and applies
/// the latest desired state again.
class DesiredStateCoordinator<T> {
  DesiredStateCoordinator({required T initialState, required DesiredStateApplier<T> apply})
    : _desiredState = initialState,
      _apply = apply;

  final DesiredStateApplier<T> _apply;
  T _desiredState;
  int _generation = 0;
  Completer<void>? _reconciliation;

  T get desiredState => _desiredState;
  int get generation => _generation;

  bool isCurrent(int generation, T desiredState) => generation == _generation && desiredState == _desiredState;

  Future<void> setDesiredState(T desiredState) {
    _desiredState = desiredState;
    _generation++;

    final pending = _reconciliation;
    if (pending != null) return pending.future;

    final completer = Completer<void>();
    _reconciliation = completer;
    unawaited(_reconcile(completer));
    return completer.future;
  }

  Future<void> _reconcile(Completer<void> completer) async {
    while (true) {
      final generation = _generation;
      final desiredState = _desiredState;
      try {
        await _apply(desiredState, generation);
      } catch (error, stackTrace) {
        // A superseded operation may fail while it is being closed/cancelled.
        // Continue toward the newer request instead of losing that request.
        if (!isCurrent(generation, desiredState)) continue;
        _completeError(completer, error, stackTrace);
        return;
      }

      if (!isCurrent(generation, desiredState)) continue;

      // Clear synchronously before completing. A request made by a completion
      // listener will therefore start a new reconciliation instead of joining
      // an already-completed one.
      if (identical(_reconciliation, completer)) {
        _reconciliation = null;
      }
      completer.complete();
      return;
    }
  }

  void _completeError(Completer<void> completer, Object error, StackTrace stackTrace) {
    if (identical(_reconciliation, completer)) {
      _reconciliation = null;
    }
    completer.completeError(error, stackTrace);
  }
}
