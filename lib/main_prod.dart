import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zeon/bootstrap.dart';
import 'package:zeon/core/logger/logger.dart';
import 'package:zeon/core/model/environment.dart';

Future<void> main() async {
  await runZonedGuarded(() async {
    final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();

    return await lazyBootstrap(widgetsBinding, Environment.prod);
  }, (error, stackTrace) => Logger.logPlatformDispatcherError(error, stackTrace));
}
