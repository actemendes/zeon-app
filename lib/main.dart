import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:zeon/bootstrap.dart';
import 'package:zeon/core/logger/logger.dart';
import 'package:zeon/core/model/environment.dart';

Future<void> main() async {
  await runZonedGuarded(() async {
    final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
    // final widgetsBinding = SentryWidgetsFlutterBinding.ensureInitialized();
    // debugPaintSizeEnabled = true;

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(statusBarColor: Colors.transparent, systemNavigationBarColor: Colors.transparent),
    );

    return await lazyBootstrap(widgetsBinding, Environment.dev);
  }, (error, stackTrace) => Logger.logPlatformDispatcherError(error, stackTrace));
}
