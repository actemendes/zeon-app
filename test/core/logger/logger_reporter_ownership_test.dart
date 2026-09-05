import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/logger/logger.dart';
import 'package:zeon/core/logger/logger_controller.dart';

void main() {
  test('disposing an old owner does not clear the replacement reporter', () async {
    LoggerController.preInit();
    final oldOwner = Object();
    final currentOwner = Object();
    final reported = Completer<String>();

    Logger.setSilentErrorReporter((trigger, error, stackTrace, message) async {}, owner: oldOwner);
    Logger.setSilentErrorReporter((trigger, error, stackTrace, message) async {
      if (!reported.isCompleted) reported.complete(trigger);
    }, owner: currentOwner);

    Logger.clearSilentErrorReporter(oldOwner);
    Logger.logPlatformDispatcherError(StateError('test'), StackTrace.current);

    expect(await reported.future, 'platform_error');
    Logger.clearSilentErrorReporter(currentOwner);
  });
}
