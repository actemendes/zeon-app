import 'package:zeon/singbox/model/core_status.dart';

/// Tracks authoritative core lifecycle signals for one explicit start.
///
/// A bare `STARTED` event is intentionally insufficient: a status listener can
/// initially attach to a core left by an older session.  Recovery is allowed
/// only after the current generation has observed `STARTING` followed by
/// `STARTED`.
class CoreStartSignalTracker {
  int _generation = 0;
  bool _sawStarting = false;
  bool _sawStarted = false;

  void reset(int generation) {
    _generation = generation;
    _sawStarting = false;
    _sawStarted = false;
  }

  void observe(int generation, CoreStatus status) {
    if (generation != _generation) return;
    if (status is CoreStarting) {
      _sawStarting = true;
      return;
    }
    if (status is CoreStarted && _sawStarting) {
      _sawStarted = true;
    }
  }

  bool confirmsStarted(int generation) => generation == _generation && _sawStarting && _sawStarted;
}
