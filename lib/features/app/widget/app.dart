import 'dart:async';

import 'package:accessibility_tools/accessibility_tools.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:toastification/toastification.dart';
import 'package:zeon/core/localization/locale_extensions.dart';
import 'package:zeon/core/localization/locale_preferences.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/constants.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/router/go_router/go_router_notifier.dart';
import 'package:zeon/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:zeon/core/theme/app_theme.dart';
import 'package:zeon/core/theme/system_bars_style.dart';
import 'package:zeon/core/theme/theme_preferences.dart';
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
bool isOnPauseCalled = false;

class App extends HookConsumerWidget with WidgetsBindingObserver, PresLogger {
  const App({super.key});

  void onInactive(WidgetRef ref) {
    if (PlatformUtils.isDesktop) return;
    // Android enters inactive during transient system UI (e.g. VPN permission dialog).
    // Closing front core here causes unnecessary start/stop flapping.
    loggy.info("skip closeFront on inactive");
  }

  void onPause(WidgetRef ref) {
    if (PlatformUtils.isDesktop) return;
    isOnPauseCalled = true;
    unawaited(ref.read(zeonCoreServiceProvider).closeFront());
  }

  void onResume(WidgetRef ref) {
    // if (PlatformUtils.isDesktop) return;
    final coreService = ref.read(zeonCoreServiceProvider);
    coreService.recordAppResume();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(coreService.init());
      ref.invalidate(activeProxyNotifierProvider);
      if (isOnPauseCalled && PlatformUtils.isAndroid) ref.invalidate(perAppProxyServiceProvider);
      isOnPauseCalled = false;
      unawaited(ref.read(notificationPollingServiceProvider).onForeground());
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    setupStateListener(ref);
    final router = ref.watch(goRouterNotiferProvider);
    final locale = ref.watch(localePreferencesProvider);
    final themeMode = ref.watch(themePreferencesProvider);
    final theme = AppTheme(themeMode, locale.preferredFontFamily);
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
    return WindowWrapper(
      ShortcutWrapper(
        ToastificationWrapper(
          child: ConnectionWrapper(
            MaterialApp.router(
              routerConfig: router,
              locale: locale.flutterLocale,
              supportedLocales: AppLocaleUtils.supportedLocales,
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              debugShowCheckedModeBanner: false,
              themeMode: themeMode.flutterThemeMode,
              theme: theme.lightTheme(null),
              darkTheme: theme.darkTheme(null),
              title: Constants.appName,
              builder: (context, child) {
                final theme = Theme.of(context);
                final appChild = child ?? const SizedBox();
                if (kDebugMode && _debugAccessibility) {
                  return AccessibilityTools(checkFontOverflows: true, child: appChild);
                }
                return AnnotatedRegion<SystemUiOverlayStyle>(
                  value: systemBarsStyleFor(theme.brightness),
                  child: appChild,
                );
              },
            ),
          ),
        ),
      ),
    );
  }

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
