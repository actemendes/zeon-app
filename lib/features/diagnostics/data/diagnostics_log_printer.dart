import 'dart:async';

import 'package:loggy/loggy.dart';
import 'package:zeon/features/diagnostics/data/error_report_redactor.dart';

class DiagnosticsLogPrinter extends LoggyPrinter {
  DiagnosticsLogPrinter({required Future<void> Function(LogRecord record) onErrorRecord, this.maxEntries = 300})
    : _onErrorRecord = onErrorRecord;

  final Future<void> Function(LogRecord record) _onErrorRecord;
  final int maxEntries;
  final List<String> _entries = [];
  final ErrorReportRedactor _redactor = const ErrorReportRedactor();

  List<String> snapshot({int limit = 120}) {
    final start = _entries.length > limit ? _entries.length - limit : 0;
    return _entries.sublist(start);
  }

  @override
  void onLog(LogRecord record) {
    _append(record);
    if (record.level.priority < LogLevel.error.priority) return;
    if (_isGlobalErrorRecord(record)) return;
    if (!shouldCaptureDiagnosticLogMessage(record.message)) return;
    unawaited(_onErrorRecord(record));
  }

  void _append(LogRecord record) {
    final time = record.time.toUtc().toIso8601String();
    final message = _redactor.redactText(record.message, maxLength: 2000);
    _entries.add('$time [${record.level.name.toUpperCase()}] [${record.loggerName}] $message');
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

  bool _isGlobalErrorRecord(LogRecord record) {
    if (record.loggerName != 'app') return false;
    final message = record.message;
    return message.startsWith('Flutter Error:') || message.startsWith('PlatformDispatcherError:');
  }
}

/// Core diagnostics are useful as context in the report log tail, but they are
/// not independent incidents. In particular, dynamic `event=...` messages and
/// one-line Go stack frames previously generated thousands of unique reports.
bool shouldCaptureDiagnosticLogMessage(String message) {
  final normalized = message.trimLeft();
  if (normalized.isEmpty || normalized.startsWith('event=')) return false;
  if (RegExp(r'^(?:goroutine \d+|created by |runtime[./]|github\.com/|google\.golang\.org/)').hasMatch(normalized)) {
    return false;
  }
  if (RegExp(r'^\S+\.go:\d+(?:\s+\+0x[0-9a-f]+)?$', caseSensitive: false).hasMatch(normalized)) {
    return false;
  }
  return true;
}
