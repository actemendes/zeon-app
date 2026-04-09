import 'package:flutter/scheduler.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'init_signal.g.dart';

@riverpod
class CoreRestartSignal extends _$CoreRestartSignal {
  bool _restartQueued = false;

  @override
  int build() => 0;

  void restart() {
    if (_restartQueued) return;
    _restartQueued = true;

    void emit() {
      _restartQueued = false;
      try {
        state++;
      } catch (_) {
        // Provider can be disposed between scheduling and emitting.
      }
    }

    final phase = SchedulerBinding.instance.schedulerPhase;
    final shouldDefer =
        phase == SchedulerPhase.transientCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks ||
        phase == SchedulerPhase.persistentCallbacks;

    if (shouldDefer) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (_restartQueued) {
          emit();
        }
      });
      return;
    }

    emit();
  }
}
