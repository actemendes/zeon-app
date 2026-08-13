import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:loggy/loggy.dart';

typedef SilentErrorReporter =
    Future<void> Function(String trigger, Object error, StackTrace? stackTrace, String? message);

class Logger {
  static final app = Loggy("app");
  static final bootstrap = Loggy("bootstrap");
  static const _maxPendingSilentErrors = 20;
  static final List<_PendingSilentError> _pendingSilentErrors = [];
  static SilentErrorReporter? _silentErrorReporter;
  static Object? _silentErrorReporterOwner;

  static void setSilentErrorReporter(SilentErrorReporter reporter, {Object? owner}) {
    _silentErrorReporter = reporter;
    _silentErrorReporterOwner = owner ?? reporter;
    if (_pendingSilentErrors.isEmpty) return;
    final pending = List<_PendingSilentError>.of(_pendingSilentErrors);
    _pendingSilentErrors.clear();
    for (final entry in pending) {
      unawaited(reporter(entry.trigger, entry.error, entry.stackTrace, entry.message));
    }
  }

  static void clearSilentErrorReporter([Object? owner]) {
    if (owner == null || identical(_silentErrorReporterOwner, owner)) {
      _silentErrorReporter = null;
      _silentErrorReporterOwner = null;
    }
  }

  static void logFlutterError(FlutterErrorDetails details) {
    if (details.silent) {
      return;
    }

    final description = details.exceptionAsString();

    app.error('Flutter Error: $description', details.exception, details.stack);
    _reportSilently('flutter_error', details.exception, details.stack, description);
  }

  static bool logPlatformDispatcherError(Object error, StackTrace stackTrace) {
    app.error('PlatformDispatcherError: $error', error, stackTrace);
    _reportSilently('platform_error', error, stackTrace, error.toString());
    return true;
  }

  static void _reportSilently(String trigger, Object error, StackTrace? stackTrace, String? message) {
    final reporter = _silentErrorReporter;
    if (reporter == null) {
      _pendingSilentErrors.add(
        _PendingSilentError(trigger: trigger, error: error, stackTrace: stackTrace, message: message),
      );
      if (_pendingSilentErrors.length > _maxPendingSilentErrors) {
        _pendingSilentErrors.removeRange(0, _pendingSilentErrors.length - _maxPendingSilentErrors);
      }
      return;
    }
    unawaited(reporter(trigger, error, stackTrace, message));
  }
}

class _PendingSilentError {
  const _PendingSilentError({required this.trigger, required this.error, this.stackTrace, this.message});

  final String trigger;
  final Object error;
  final StackTrace? stackTrace;
  final String? message;
}
