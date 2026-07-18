// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:loggy/loggy.dart';
import 'package:zeon/core/security/sensitive_text_redactor.dart';

class ConsolePrinter extends LoggyPrinter {
  const ConsolePrinter({this.showColors = false});

  final bool showColors;

  static final _levelColors = {
    LogLevel.debug: AnsiColor(foregroundColor: AnsiColor.grey(0.5), italic: true),
    LogLevel.info: AnsiColor(foregroundColor: 35),
    LogLevel.warning: AnsiColor(foregroundColor: 214),
    LogLevel.error: AnsiColor(foregroundColor: 196),
  };

  @override
  void onLog(LogRecord record) {
    // Production builds must not emit application data to logcat or an
    // attached desktop console. Persistent logs use the redacting printer.
    if (kReleaseMode) return;

    final colorize = showColors && stdout.supportsAnsiEscapes;
    final time = record.time.toIso8601String().split('T')[1];
    final callerFrame = record.callerFrame == null ? ' ' : ' (${record.callerFrame?.location}) ';

    final String logLevel;
    if (colorize) {
      logLevel = record.level.name.toUpperCase().padRight(8);
    } else {
      logLevel = "[${record.level.name.toUpperCase()}]".padRight(10);
    }

    final color = showColors ? levelColor(record.level) ?? AnsiColor() : AnsiColor();

    print(color('$time $logLevel [${record.loggerName}]$callerFrame${record.message}'));

    if (record.stackTrace != null) {
      print(record.stackTrace);
    }
  }

  AnsiColor? levelColor(LogLevel level) {
    return _levelColors[level];
  }
}

class FileLogPrinter extends LoggyPrinter {
  FileLogPrinter(
    String filePath, {
    this.minLevel = LogLevel.debug,
    SensitiveTextRedactor redactor = const SensitiveTextRedactor(),
  }) : _logFile = File(filePath),
       _redactor = redactor;

  final File _logFile;
  final LogLevel minLevel;
  final SensitiveTextRedactor _redactor;

  late final _sink = _logFile.openWrite(mode: FileMode.writeOnly);

  @override
  void onLog(LogRecord record) {
    if (record.level.priority < minLevel.priority) return;

    final time = record.time.toIso8601String().split('T')[1];
    _sink.writeln(_redactor.redact("$time - $record"));
    if (record.error != null) {
      _sink.writeln(_redactor.redact(record.error.toString()));
    }
    if (record.stackTrace != null) {
      _sink.writeln(_redactor.redact(record.stackTrace.toString()));
    }
  }

  Future<void> dispose() => _sink.close();
}
