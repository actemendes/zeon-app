import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class ErrorReportQueue {
  ErrorReportQueue({required SharedPreferences preferences}) : _preferences = preferences;

  static const _queueKey = 'diagnostics_error_report_queue_v1';
  static const _maxReports = 50;
  static const _maxAttempts = 12;

  final SharedPreferences _preferences;
  Future<void> _mutationTail = Future<void>.value();

  Future<void> enqueue(Map<String, dynamic> report) {
    return _synchronized(() async {
      final queue = _readQueue();
      final eventId = report['event_id']?.toString();
      if (eventId != null && queue.any((entry) => entry.eventId == eventId)) {
        return;
      }
      queue.add(
        QueuedErrorReport(eventId: eventId ?? '', report: report, attempts: 0, nextAttemptAt: DateTime.now().toUtc()),
      );
      while (queue.length > _maxReports) {
        queue.removeAt(0);
      }
      await _writeQueue(queue);
    });
  }

  List<QueuedErrorReport> dueReports(DateTime now) {
    final queue = _readQueue();
    return queue
        .where((entry) => entry.attempts < _maxAttempts && !entry.nextAttemptAt.isAfter(now.toUtc()))
        .toList(growable: false);
  }

  Future<void> remove(String eventId) {
    return _synchronized(() async {
      final queue = _readQueue()..removeWhere((entry) => entry.eventId == eventId);
      await _writeQueue(queue);
    });
  }

  Future<void> markFailed(String eventId) {
    return _synchronized(() async {
      final queue = _readQueue();
      final index = queue.indexWhere((entry) => entry.eventId == eventId);
      if (index == -1) return;

      final current = queue[index];
      final attempts = current.attempts + 1;
      if (attempts >= _maxAttempts) {
        queue.removeAt(index);
      } else {
        queue[index] = current.copyWith(
          attempts: attempts,
          nextAttemptAt: DateTime.now().toUtc().add(_retryDelay(attempts)),
        );
      }
      await _writeQueue(queue);
    });
  }

  List<QueuedErrorReport> _readQueue() {
    final raw = _preferences.getString(_queueKey);
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((entry) => QueuedErrorReport.fromJson(entry.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeQueue(List<QueuedErrorReport> queue) {
    return _preferences.setString(_queueKey, jsonEncode(queue.map((entry) => entry.toJson()).toList(growable: false)));
  }

  Duration _retryDelay(int attempts) {
    final seconds = switch (attempts) {
      <= 1 => 15,
      2 => 60,
      3 => 300,
      4 => 900,
      _ => 3600,
    };
    return Duration(seconds: seconds);
  }

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _mutationTail = _mutationTail.catchError((_) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

class QueuedErrorReport {
  const QueuedErrorReport({
    required this.eventId,
    required this.report,
    required this.attempts,
    required this.nextAttemptAt,
  });

  final String eventId;
  final Map<String, dynamic> report;
  final int attempts;
  final DateTime nextAttemptAt;

  factory QueuedErrorReport.fromJson(Map<String, dynamic> json) {
    final reportRaw = json['report'];
    return QueuedErrorReport(
      eventId: json['event_id']?.toString() ?? '',
      report: reportRaw is Map ? reportRaw.cast<String, dynamic>() : <String, dynamic>{},
      attempts: switch (json['attempts']) {
        final int value => value,
        final num value => value.toInt(),
        final String value => int.tryParse(value) ?? 0,
        _ => 0,
      },
      nextAttemptAt: DateTime.tryParse(json['next_attempt_at']?.toString() ?? '')?.toUtc() ?? DateTime.now().toUtc(),
    );
  }

  QueuedErrorReport copyWith({int? attempts, DateTime? nextAttemptAt}) {
    return QueuedErrorReport(
      eventId: eventId,
      report: report,
      attempts: attempts ?? this.attempts,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'event_id': eventId,
      'report': report,
      'attempts': attempts,
      'next_attempt_at': nextAttemptAt.toUtc().toIso8601String(),
    };
  }
}
