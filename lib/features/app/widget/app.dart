import 'dart:async';

import 'package:accessibility_tools/accessibility_tools.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:toastification/toastification.dart';
import 'package:upgrader/upgrader.dart';
import 'package:zeon/core/app_info/app_info_provider.dart';
import 'package:zeon/core/localization/locale_extensions.dart';
import 'package:zeon/core/localization/locale_preferences.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/constants.dart';
import 'package:zeon/core/model/environment.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/router/dialog/dialog_notifier.dart';
import 'package:zeon/core/router/go_router/go_router_notifier.dart';
import 'package:zeon/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:zeon/core/theme/app_theme.dart';
import 'package:zeon/core/theme/theme_preferences.dart';
import 'package:zeon/features/app_update/notifier/app_update_notifier.dart';
import 'package:zeon/features/connection/widget/connection_wrapper.dart';
import 'package:zeon/features/notifications/data/notification_data_providers.dart';
import 'package:zeon/features/per_app_proxy/overview/per_app_proxy_service_notifier.dart';
import 'package:zeon/features/profile/notifier/profiles_update_notifier.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/features/shortcut/shortcut_wrapper.dart';
import 'package:zeon/features/system_tray/notifier/system_tray_notifier.dart';
import 'package:zeon/features/window/widget/window_wrapper.dart';
import 'package:zeon/utils/utils.dart';
import 'package:zeon/zeoncore/zeon_core_service_provider.dart';

bool _debugAccessibility = false;
bool _wasPaused = false;
int _appLifecycleGeneration = 0;

class App extends HookConsumerWidget with WidgetsBindingObserver, PresLogger {
  const App({super.key});

  void onInactive(WidgetRef ref) {
    _appLifecycleGeneration++;
    if (PlatformUtils.isDesktop) return;
    // Android enters inactive during transient system UI (e.g. VPN permission dialog).
    // Closing front core here causes unnecessary start/stop flapping.
    loggy.info("skip closeFront on inactive");
  }

  void onPause(WidgetRef ref) {
    _appLifecycleGeneration++;
    if (PlatformUtils.isDesktop) return;
    _wasPaused = true;
    unawaited(
      _logLifecycleFailure(ref.read(zeonCoreServiceProvider).setForegroundDesired(false), operationName: "pause"),
    );
  }

  void onResume(WidgetRef ref) {
    final generation = ++_appLifecycleGeneration;
    final wasPaused = _wasPaused;
    final shouldRestoreForegroundCore = wasPaused && !PlatformUtils.isDesktop;
    final foregroundReady = shouldRestoreForegroundCore
        ? _logLifecycleFailure(ref.read(zeonCoreServiceProvider).setForegroundDesired(true), operationName: "resume")
        : Future<bool>.value(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_finishResume(ref, generation, wasPaused, foregroundReady));
    });
  }

  Future<void> _finishResume(WidgetRef ref, int generation, bool wasPaused, Future<bool> foregroundReady) async {
    final setupSucceeded = await foregroundReady;
    if (generation != _appLifecycleGeneration || WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      loggy.debug("skip stale resume callback [generation=$generation]");
      return;
    }

    // Consumers must bind only after the foreground channel replacement has
    // completed. setup() also emits coreRestartSignal for other gRPC streams.
    if (setupSucceeded) {
      ref.invalidate(activeProxyNotifierProvider);
    } else {
      loggy.warning("skip active proxy refresh: foreground setup did not complete");
    }
    if (wasPaused && PlatformUtils.isAndroid) ref.invalidate(perAppProxyServiceProvider);
    // Keep the restore intent after a failed setup so the next resumed event
    // can retry without requiring another pause first.
    _wasPaused = wasPaused && !setupSucceeded;
    unawaited(ref.read(notificationPollingServiceProvider).onForeground());
  }

  Future<bool> _logLifecycleFailure(Future<bool> operation, {required String operationName}) async {
    try {
      return await operation;
    } catch (error, stackTrace) {
      loggy.warning("foreground lifecycle $operationName failed", error, stackTrace);
      return false;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    setupStateListener(ref);
    final router = ref.watch(goRouterNotiferProvider);
    final locale = ref.watch(localePreferencesProvider);
    final themeMode = ref.watch(themePreferencesProvider);
    final theme = AppTheme(themeMode, locale.preferredFontFamily);
    final appInfo = ref.watch(appInfoProvider).requireValue;
    final upgrader = appInfo.release == Release.googlePlay ? ref.watch(upgraderProvider) : null;
    final activeBreakpoint = Breakpoint(context).activeBreakpoint;

    ref.listen(foregroundProfilesUpdateNotifierProvider, (_, _) {});
    if (PlatformUtils.isAndroid) ref.listen(perAppProxyServiceProvider, (_, _) {});
    if (PlatformUtils.isDesktop) ref.listen(systemTrayNotifierProvider, (_, _) {});
    ref.listen(Preferences.remoteNotifications, (_, _) {
      unawaited(ref.read(notificationPollingServiceProvider).configurePlatformSchedulers());
    });

    // updating ActiveBreakpointNotifier value
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(ref.read(notificationPollingServiceProvider).start());
      });
      return null;
    }, const []);
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(activeBreakpointNotifierProvider.notifier).update(activeBreakpoint);
      });
      return null;
    }, [activeBreakpoint]);
    useEffect(() {
      if (appInfo.release != Release.general) return null;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final newVersion = await ref.read(appUpdateNotifierProvider.notifier).checkAutomatically();
        if (!context.mounted || newVersion == null) return;
        await ref
            .read(dialogNotifierProvider.notifier)
            .showNewVersion(currentVersion: appInfo.presentVersion, newVersion: newVersion, canIgnore: false);
      });
      return null;
    }, [appInfo.release]);
    return WindowWrapper(
      ShortcutWrapper(
        ToastificationWrapper(
          child: ConnectionWrapper(
            DynamicColorBuilder(
              builder: (ColorScheme? lightColorScheme, ColorScheme? darkColorScheme) {
                return MaterialApp.router(
                  routerConfig: router,
                  locale: locale.flutterLocale,
                  supportedLocales: AppLocaleUtils.supportedLocales,
                  localizationsDelegates: GlobalMaterialLocalizations.delegates,
                  debugShowCheckedModeBanner: false,
                  themeMode: themeMode.flutterThemeMode,
                  theme: theme.lightTheme(lightColorScheme),
                  darkTheme: theme.darkTheme(darkColorScheme),
                  title: Constants.appName,
                  builder: (context, child) {
                    final theme = Theme.of(context);
                    var appChild = child ?? const SizedBox();
                    if (upgrader != null) {
                      appChild = UpgradeAlert(
                        upgrader: upgrader,
                        navigatorKey: router.routerDelegate.navigatorKey,
                        child: appChild,
                      );
                    }
                    if (kDebugMode && _debugAccessibility) {
                      return AccessibilityTools(checkFontOverflows: true, child: appChild);
                    }
                    final isDark = theme.brightness == Brightness.dark;
                    return AnnotatedRegion<SystemUiOverlayStyle>(
                      value: SystemUiOverlayStyle(
                        statusBarColor: theme.scaffoldBackgroundColor,
                        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
                        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
                        systemNavigationBarColor: theme.scaffoldBackgroundColor,
                        systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
                      ),
                      child: appChild,
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // @override
  // Widget build1(BuildContext context, WidgetRef ref) {
  //   setupStateListener(ref);
  //   // setupQuickSettings(ref);
  //   final router = ref.watch(routerProvider);
  //   final locale = ref.watch(localePreferencesProvider);
  //   final themeMode = ref.watch(themePreferencesProvider);
  //   final theme = AppTheme(themeMode, locale.preferredFontFamily);
  //   final upgrader = ref.watch(upgraderProvider);

  //   ref.listen(foregroundProfilesUpdateNotifierProvider, (_, __) {});

  //   return WindowWrapper(
  //     TrayWrapper(
  //       ShortcutWrapper(
  //         ConnectionWrapper(
  //           PlatformProvider(
  //               settings: PlatformSettingsData(
  //                 iosUsesMaterialWidgets: true,
  //               ),
  //               builder: (context) => DynamicColorBuilder(
  //                     builder: (ColorScheme? lightColorScheme, ColorScheme? darkColorScheme) {
  //                       return PlatformApp.router(
  //                         routerConfig: router,
  //                         locale: locale.flutterLocale,
  //                         supportedLocales: AppLocaleUtils.supportedLocales,
  //                         localizationsDelegates: GlobalMaterialLocalizations.delegates,
  //                         debugShowCheckedModeBanner: false,
  //                         material: (context, platform) => MaterialAppRouterData(
  //                           theme: theme.lightTheme(lightColorScheme),
  //                           darkTheme: theme.darkTheme(darkColorScheme),
  //                           themeMode: themeMode.flutterThemeMode,
  //                         ),
  //                         cupertino: (context, platform) {
  //                           final sysDark = MediaQuery.of(context).platformBrightness == Brightness.dark;

  //                           return CupertinoAppRouterData(theme: theme.cupertinoThemeData(sysDark, lightColorScheme, darkColorScheme));
  //                         },
  //                         title: Constants.appName,
  //                         builder: (context, child) {
  //                           child = UpgradeAlert(
  //                             upgrader: upgrader,
  //                             navigatorKey: router.routerDelegate.navigatorKey,
  //                             child: child ?? const SizedBox(),
  //                           );
  //                           if (kDebugMode && _debugAccessibility) {
  //                             return AccessibilityTools(
  //                               checkFontOverflows: true,
  //                               child: child,
  //                             );
  //                           }
  //                           return child;
  //                         },
  //                       );
  //                     },
  //                   )),
  //         ),
  //       ),
  //     ),
  //   );
  // }

  void setupStateListener(WidgetRef ref) {
    final appLifecycleState = useAppLifecycleState();

    useEffect(() {
      loggy.info("current app state");
      loggy.info(appLifecycleState);
      if (appLifecycleState == AppLifecycleState.paused) {
        onPause(ref);
      } else if (appLifecycleState == AppLifecycleState.inactive) {
        onInactive(ref);
      } else if (appLifecycleState == AppLifecycleState.resumed) {
        onResume(ref);
      }
      return null;
    }, [appLifecycleState]);
  }
}
