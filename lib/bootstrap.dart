import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/logger/logger.dart';
import 'package:hiddify/core/logger/logger_controller.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_migration.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/theme/app_theme_mode.dart';
import 'package:hiddify/features/app/widget/app.dart';
import 'package:hiddify/features/auto_start/notifier/auto_start_notifier.dart';
import 'package:hiddify/features/bootstrap/widget/bootstrap_splash_screen.dart';

import 'package:hiddify/features/log/data/log_data_providers.dart';
import 'package:hiddify/features/mobile/data/mobile_bootstrap_import_service.dart';
import 'package:hiddify/features/per_app_proxy/data/selected_data_provider.dart';
import 'package:hiddify/features/per_app_proxy/model/per_app_proxy_backup.dart';
import 'package:hiddify/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:hiddify/features/profile/data/debug_profile_bootstrap_service.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/system_tray/notifier/system_tray_notifier.dart';
import 'package:hiddify/features/window/notifier/window_notifier.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hiddify/riverpod_observer.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  await _safeInit("per-app proxy defaults", () => _seedPerAppProxyDefaults(container), timeout: 5000);

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

  await _init("hiddify-core", () => container.read(hiddifyCoreServiceProvider).init());
  final mobileBootstrapImportService = MobileBootstrapImportService(
    httpClient: container.read(httpClientProvider),
    profileRepository: profileRepository,
    profileDataSource: profileDataSource,
    preferences: preferences,
  );
  unawaited(_safeInit("mobile auto import", () => mobileBootstrapImportService.run(), timeout: 15000));
  unawaited(_retryMobileAutoImport(mobileBootstrapImportService));
  await _safeInit("active profile", () => container.read(activeProfileProvider.future), timeout: 1000);

  if (!kIsWeb) {
    // await _safeInit(
    //   "deep link service",
    //   () => container.read(deepLinkNotifierProvider.future),
    //   timeout: 1000,
    // );

    if (PlatformUtils.isDesktop) {
      await _safeInit("system tray", () => container.read(systemTrayNotifierProvider.future), timeout: 1000);
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

Future<void> _seedPerAppProxyDefaults(ProviderContainer container) async {
  if (!PlatformUtils.isAndroid) return;
  final prefs = container.read(sharedPreferencesProvider).requireValue;
  const seedKey = "per_app_proxy_seed_v3_done";
  if (prefs.getBool(seedKey) ?? false) return;

  const excludePkgs = <String>[
    "com.apteka.sklad",
    "com.avito.android",
    "com.carshering",
    "com.gnivts.selfemployed",
    "com.platfomni.vita",
    "com.profibackoffice.reactnative",
    "com.vk.equals",
    "com.vk.im",
    "com.vkontakte.android",
    "com.vtosters.lite",
    "com.yandex.bank",
    "com.yandex.searchapp",
    "ru.apteki.plus",
    "ru.belkacar.belkacar",
    "ru.dublgis.dgismobile",
    "ru.fns.lkfl",
    "ru.gazprombank.android.mobilebank.app",
    "ru.gosuslugi.auto",
    "ru.gosuslugi.goskey",
    "ru.kinopoisk",
    "ru.megafon.mlk",
    "ru.mts.mymts",
    "ru.nspk.mirpay",
    "ru.oneme.app",
    "ru.parkomatica",
    "ru.poryadok.poryadok_flutter_app",
    "ru.profi.client",
    "ru.pyaterochka.app.browser",
    "ru.qugo.mobile",
    "ru.rostel",
    "ru.rutube.app",
    "ru.sbcs.store",
    "ru.tander.magnit",
    "ru.tele2.mytele2",
    "ru.vk.store",
    "ru.yandex.disk",
    "ru.yandex.music",
    "ru.yandex.taxi",
    "ru.yandex.taximeter",
    "ru.yandex.telemost",
    "ru.yandex.yandexmaps",
    "ru.zenmoney.androidsub",
    "shop.tornado.store",
    "youdrive.today",
  ];

  final currentMode = container.read(Preferences.perAppProxyMode);
  final currentInclude = container.read(Preferences.includeApps);
  final currentExclude = container.read(Preferences.excludeApps);
  final shouldApplyDefaults = currentMode == PerAppProxyMode.off && currentInclude.isEmpty && currentExclude.isEmpty;
  if (shouldApplyDefaults) {
    await container.read(Preferences.perAppProxyMode.notifier).update(PerAppProxyMode.exclude);
    await container.read(Preferences.includeApps.notifier).update(const []);
    await container.read(Preferences.excludeApps.notifier).update(excludePkgs);
    await container
        .read(appProxyDataSourceProvider)
        .importPkgs(
          backup: const PerAppProxyBackup(
            include: PerAppProxyBackupMode(selected: [], deselected: []),
            exclude: PerAppProxyBackupMode(selected: excludePkgs, deselected: []),
          ),
        );
    await prefs.setBool(seedKey, true);
    return;
  }
  // One-time self-heal for existing installs:
  // keep user's exclude mode, append only missing default direct apps so they appear in UI.
  if (currentMode == PerAppProxyMode.exclude) {
    final merged = <String>[...currentExclude, ...excludePkgs.where((pkg) => !currentExclude.contains(pkg))];
    if (merged.length != currentExclude.length) {
      await container.read(Preferences.excludeApps.notifier).update(merged);
      await container
          .read(appProxyDataSourceProvider)
          .importPkgs(
            backup: PerAppProxyBackup(
              include: const PerAppProxyBackupMode(selected: [], deselected: []),
              exclude: PerAppProxyBackupMode(selected: merged, deselected: const []),
            ),
          );
    }
  }
  await prefs.setBool(seedKey, true);
}

Future<void> _retryMobileAutoImport(MobileBootstrapImportService service) async {
  const retryDelays = <Duration>[
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 40),
  ];
  for (final delay in retryDelays) {
    await Future.delayed(delay);
    try {
      await service.run();
    } catch (_) {
      // Intentionally ignored: best-effort background retries.
    }
  }
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
