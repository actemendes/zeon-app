import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/app_info/app_info_provider.dart';
import 'package:zeon/core/directories/directories_provider.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/logger/logger.dart';
import 'package:zeon/core/logger/logger_controller.dart';
import 'package:zeon/core/model/environment.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/preferences/preferences_migration.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/features/app/widget/app.dart';
import 'package:zeon/features/auto_start/notifier/auto_start_notifier.dart';
import 'package:zeon/features/bootstrap/widget/bootstrap_splash_screen.dart';
import 'package:zeon/features/diagnostics/data/diagnostics_providers.dart';
import 'package:zeon/features/log/data/log_data_providers.dart';
import 'package:zeon/features/mobile/data/mobile_bootstrap_import_service.dart';
import 'package:zeon/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:zeon/features/per_app_proxy/data/legacy_seeded_routing_cleanup.dart';
import 'package:zeon/features/per_app_proxy/data/selected_data_provider.dart';
import 'package:zeon/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:zeon/features/profile/data/debug_profile_bootstrap_service.dart';
import 'package:zeon/features/profile/data/profile_data_providers.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/system_tray/notifier/system_tray_notifier.dart';
import 'package:zeon/features/window/notifier/window_notifier.dart';
import 'package:zeon/riverpod_observer.dart';
import 'package:zeon/utils/utils.dart';
import 'package:zeon/zeoncore/zeon_core_service_provider.dart';

Future<void> lazyBootstrap(WidgetsBinding widgetsBinding, Environment env) async {
  final shouldPreserveNativeSplash = await _shouldShowNativeSplashOnThisRun();
  if (shouldPreserveNativeSplash) {
    FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);
  }
  LoggerController.preInit();
  FlutterError.onError = Logger.logFlutterError;
  WidgetsBinding.instance.platformDispatcher.onError = Logger.logPlatformDispatcherError;

  runApp(_BootstrapHost(environment: env, shouldRemoveNativeSplash: shouldPreserveNativeSplash));
}

class _BootstrapHost extends StatefulWidget {
  const _BootstrapHost({required this.environment, required this.shouldRemoveNativeSplash});

  final Environment environment;
  final bool shouldRemoveNativeSplash;

  @override
  State<_BootstrapHost> createState() => _BootstrapHostState();
}

class _BootstrapHostState extends State<_BootstrapHost> {
  late final Future<ProviderContainer> _bootstrapFuture;
  AppThemeMode _initialThemeMode = AppThemeMode.system;

  @override
  void initState() {
    super.initState();
    _bootstrapFuture = _bootstrapAfterFirstFrame();
    unawaited(_loadInitialThemeMode());
    if (widget.shouldRemoveNativeSplash) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FlutterNativeSplash.remove();
      });
    }
  }

  Future<ProviderContainer> _bootstrapAfterFirstFrame() async {
    await WidgetsBinding.instance.endOfFrame;
    return _bootstrapContainer(widget.environment);
  }

  Future<void> _loadInitialThemeMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final persisted = prefs.getString("theme_mode");
      final themeMode = switch (persisted) {
        null => AppThemeMode.system,
        "black" => AppThemeMode.dark,
        _ => AppThemeMode.values.firstWhere((mode) => mode.name == persisted, orElse: () => AppThemeMode.system),
      };
      if (!mounted) return;
      setState(() {
        _initialThemeMode = themeMode;
      });
    } catch (_) {
      // Fall back to system brightness for the bootstrap splash.
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ProviderContainer>(
      future: _bootstrapFuture,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return ProviderScope(
            parent: snapshot.requireData,
            observers: [RiverpodObserver()],
            child: SentryUserInteractionWidget(child: const App()),
          );
        }

        if (snapshot.hasError) {
          return _BootstrapFailureApp(error: snapshot.error);
        }

        return _BootstrapSplashApp(themeMode: _initialThemeMode);
      },
    );
  }
}

class _BootstrapSplashApp extends StatelessWidget {
  const _BootstrapSplashApp({required this.themeMode});

  final AppThemeMode themeMode;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(debugShowCheckedModeBanner: false, home: BootstrapSplashScreen(themeMode: themeMode));
  }
}

class _BootstrapFailureApp extends StatelessWidget {
  const _BootstrapFailureApp({required this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '$error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

Future<ProviderContainer> _bootstrapContainer(Environment env) async {
  final stopWatch = Stopwatch()..start();

  final container = ProviderContainer(overrides: [environmentProvider.overrideWithValue(env)]);

  await _init("directories", () => container.read(appDirectoriesProvider.future));
  LoggerController.init(container.read(logPathResolverProvider).appFile().path);

  final appInfo = await _init("app info", () => container.read(appInfoProvider.future));
  await _init("preferences", () => container.read(sharedPreferencesProvider.future));

  await _init("preferences migration", () async {
    try {
      await PreferencesMigration(sharedPreferences: container.read(sharedPreferencesProvider).requireValue).migrate();
    } catch (e, stackTrace) {
      Logger.bootstrap.error("preferences migration failed", e, stackTrace);
      if (env == Environment.dev) rethrow;
      Logger.bootstrap.info("clearing preferences");
      await container.read(sharedPreferencesProvider).requireValue.clear();
    }
  });

  final debug = container.read(debugModeNotifierProvider) || kDebugMode;
  await _safeInit("per-app proxy migration", () => _cleanupLegacyPerAppProxyDefaults(container), timeout: 5000);

  if (PlatformUtils.isDesktop) {
    await _init("window controller", () => container.read(windowNotifierProvider.future));

    final silentStart = container.read(Preferences.silentStart);
    Logger.bootstrap.debug("silent start [${silentStart ? "Enabled" : "Disabled"}]");
    if (!silentStart) {
      await container.read(windowNotifierProvider.notifier).show(focus: false);
    } else {
      Logger.bootstrap.debug("silent start, remain hidden accessible via tray");
    }
    await _init("auto start service", () => container.read(autoStartNotifierProvider.future));
  }
  await _init("logs repository", () => container.read(logRepositoryProvider.future));
  await _init("logger controller", () => LoggerController.postInit(debug));

  Logger.bootstrap.info(appInfo.format());

  await _init("profile repository", () => container.read(profileRepositoryProvider.future));
  final profileRepository = container.read(profileRepositoryProvider).requireValue;
  final profileDataSource = container.read(profileDataSourceProvider);
  final preferences = container.read(sharedPreferencesProvider).requireValue;

  final debugProfileBootstrapService = DebugProfileBootstrapService(
    environment: env,
    profileRepository: profileRepository,
    profileDataSource: profileDataSource,
    preferences: preferences,
  );
  await _safeInit("debug profile bootstrap", () => debugProfileBootstrapService.run(), timeout: 10000);

  await _init("translations", () => container.read(translationsProvider.future));

  await _init("zeon-core", () => container.read(zeonCoreServiceProvider).init());
  final mobileBootstrapImportService = container.read(mobileBootstrapImportServiceProvider);
  if (PlatformUtils.isMobile) {
    await _safeInit(
      "mobile single profile cleanup",
      () => mobileBootstrapImportService.enforceSingleProfile(),
      timeout: 5000,
    );
  }
  // Try the ordinary network during startup. If it is blocked, the UI-level
  // retry can ask the user to start VPN and transparently repeat through it.
  final mobileAutoImportResult = await _safeInit(
    "mobile auto import",
    () => mobileBootstrapImportService.run(mode: MobileConnLinkImportMode.standard),
    timeout: 18000,
  );
  if (mobileAutoImportResult == true) {
    await _safeInit(
      "wait active profile after mobile auto import",
      () => profileDataSource.watchActiveProfile().firstWhere((profile) => profile != null),
      timeout: 3000,
    );
  } else if (PlatformUtils.isMobile) {
    final activeProfile = await _safeInit(
      "check active profile before embedded bootstrap",
      () => profileDataSource.watchActiveProfile().first,
      timeout: 1000,
    );
    final shouldInstallEmbeddedProfile =
        activeProfile == null || await mobileBootstrapImportService.hasActiveEmbeddedProfile();
    if (shouldInstallEmbeddedProfile) {
      final embeddedInstalled = await _safeInit(
        "mobile embedded bootstrap profile",
        () => mobileBootstrapImportService.ensureEmbeddedFallbackProfile(),
        timeout: 5000,
      );
      if (embeddedInstalled == true) {
        await _safeInit(
          "wait active embedded bootstrap profile",
          () => profileDataSource.watchActiveProfile().firstWhere((profile) => profile != null),
          timeout: 3000,
        );
      }
    }
  }
  await _safeInit("active profile", () => container.read(activeProfileProvider.future), timeout: 1000);
  await _safeInit("error reports", () => container.read(errorReportControllerProvider).init(), timeout: 3000);

  if (!kIsWeb) {
    // await _safeInit(
    //   "deep link service",
    //   () => container.read(deepLinkNotifierProvider.future),
    //   timeout: 1000,
    // );

    if (PlatformUtils.isDesktop) {
      _initSystemTrayInBackground(container);
    }

    if (PlatformUtils.isAndroid) {
      await _safeInit("android display mode", () async {
        await FlutterDisplayMode.setHighRefreshRate();
      });
    }
  }

  Logger.bootstrap.info("bootstrap took [${stopWatch.elapsedMilliseconds}ms]");
  stopWatch.stop();
  return container;
}

Future<bool> _shouldShowNativeSplashOnThisRun() async {
  if (kIsWeb || !PlatformUtils.isMobile) return false;
  const key = "native_splash_first_launch_done";
  final prefs = await SharedPreferences.getInstance();
  final done = prefs.getBool(key) ?? false;
  if (done) return false;
  await prefs.setBool(key, true);
  return true;
}

Future<void> _cleanupLegacyPerAppProxyDefaults(ProviderContainer container) async {
  if (!PlatformUtils.isAndroid) return;
  final prefs = container.read(sharedPreferencesProvider).requireValue;
  final result = await LegacySeededRoutingCleanup(
    preferences: prefs,
    dataSource: container.read(appProxyDataSourceProvider),
  ).run();

  if (result.shouldDisableExcludeMode && container.read(Preferences.perAppProxyMode) == PerAppProxyMode.exclude) {
    await container.read(Preferences.perAppProxyMode.notifier).update(PerAppProxyMode.off);
  }
}

void _initSystemTrayInBackground(ProviderContainer container) {
  final stopWatch = Stopwatch()..start();
  Logger.bootstrap.info("initializing [system tray] in background");
  unawaited(
    container
        .read(systemTrayNotifierProvider.future)
        .then((_) {
          Logger.bootstrap.debug("[system tray] initialized in ${stopWatch.elapsedMilliseconds}ms");
        })
        .catchError((Object e, StackTrace stackTrace) {
          Logger.bootstrap.warning(
            "[system tray] background initialization failed after ${stopWatch.elapsedMilliseconds}ms",
            e,
            stackTrace,
          );
        })
        .whenComplete(stopWatch.stop),
  );
}

Future<T> _init<T>(String name, Future<T> Function() initializer, {int? timeout}) async {
  final stopWatch = Stopwatch()..start();
  Logger.bootstrap.info("initializing [$name]");
  Future<T> func() => timeout != null ? initializer().timeout(Duration(milliseconds: timeout)) : initializer();
  try {
    final result = await func();
    Logger.bootstrap.debug("[$name] initialized in ${stopWatch.elapsedMilliseconds}ms");
    return result;
  } catch (e, stackTrace) {
    Logger.bootstrap.error("[$name] error initializing", e, stackTrace);
    rethrow;
  } finally {
    stopWatch.stop();
  }
}

Future<T?> _safeInit<T>(String name, Future<T> Function() initializer, {int? timeout}) async {
  try {
    return await _init(name, initializer, timeout: timeout);
  } catch (e) {
    return null;
  }
}
