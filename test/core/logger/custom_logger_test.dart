import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loggy/loggy.dart';
import 'package:zeon/core/logger/custom_logger.dart';

void main() {
  test('file logger redacts secrets and honors its minimum level', () async {
    final tempDir = await Directory.systemTemp.createTemp('zeon-log-test-');
    addTearDown(() => tempDir.delete(recursive: true));
    final logFile = File('${tempDir.path}${Platform.pathSeparator}app.log');
    final printer = FileLogPrinter(logFile.path, minLevel: LogLevel.info);

    printer.onLog(LogRecord(LogLevel.debug, 'debug-secret', 'test'));
    printer.onLog(
      LogRecord(
        LogLevel.info,
        'jwt=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signature api_key=mob_aabbccddeeff001122334455',
        'test',
        'Bearer access-token',
        StackTrace.fromString('request failed at https://private.example/path'),
      ),
    );
    await printer.dispose();

    final contents = await logFile.readAsString();
    expect(contents, isNot(contains('debug-secret')));
    expect(contents, isNot(contains('signature')));
    expect(contents, isNot(contains('mob_aabbccddeeff001122334455')));
    expect(contents, isNot(contains('access-token')));
    expect(contents, isNot(contains('private.example')));
    expect(contents, contains('<redacted>'));
  });
}
