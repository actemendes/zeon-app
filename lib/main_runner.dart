import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:zeon/bootstrap.dart';
import 'package:zeon/core/analytics/analytics_filter.dart';
import 'package:zeon/core/logger/logger.dart';
import 'package:zeon/core/model/environment.dart';

Future<void> runZeonApp(Environment environment) async {
  Future<void> appRunner() async {
    await runZonedGuarded(
      () async {
        final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();

        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        SystemChrome.setSystemUIOverlayStyle(
          const SystemUiOverlayStyle(statusBarColor: Colors.transparent, systemNavigationBarColor: Colors.transparent),
        );

        await lazyBootstrap(widgetsBinding, environment);
      },
      (error, stackTrace) {
        Logger.logPlatformDispatcherError(error, stackTrace);
        if (Sentry.isEnabled) {
          unawaited(Sentry.captureException(error, stackTrace: stackTrace));
        }
      },
    );
  }

  final dsn = Environment.sentryDSN.trim();
  if (dsn.isEmpty) {
    await appRunner();
    return;
  }

  await SentryFlutter.init((options) {
    options
      ..dsn = dsn
      ..environment = environment.name
      ..sendDefaultPii = false
      ..attachStacktrace = true
      ..enableNativeCrashHandling = true
      ..enableAutoSessionTracking = true
      ..enableAppHangTracking = true
      ..appHangTimeoutInterval = const Duration(seconds: 5)
      ..beforeSend = sentryBeforeSend;
  }, appRunner: appRunner);
}
