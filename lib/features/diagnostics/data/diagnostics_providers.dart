import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/app_info/app_info_provider.dart';
import 'package:zeon/core/http_client/http_client_provider.dart';
import 'package:zeon/core/localization/locale_preferences.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/connection/data/connection_data_providers.dart';
import 'package:zeon/features/diagnostics/data/error_report_controller.dart';
import 'package:zeon/features/diagnostics/data/error_report_queue.dart';
import 'package:zeon/features/diagnostics/data/error_report_sender.dart';
import 'package:zeon/features/log/data/log_data_providers.dart';
import 'package:zeon/features/mobile/data/stable_device_id_service.dart';
import 'package:zeon/features/notifications/data/notification_data_providers.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/zeoncore/zeon_core_service_provider.dart';

final errorReportQueueProvider = Provider<ErrorReportQueue>((ref) {
  return ErrorReportQueue(preferences: ref.watch(sharedPreferencesProvider).requireValue);
});

final stableDeviceIdServiceProvider = Provider<StableDeviceIdService>((ref) {
  return StableDeviceIdService(preferences: ref.watch(sharedPreferencesProvider).requireValue);
});

final errorReportSenderProvider = Provider<ErrorReportSender>((ref) {
  return ErrorReportSender(
    httpClient: ref.watch(httpClientProvider),
    deviceAuth: ref.watch(notificationDeviceAuthProvider),
  );
});

final errorReportControllerProvider = Provider<ErrorReportController>((ref) {
  final appLocale = ref.watch(localePreferencesProvider);
  final locale = appLocale.countryCode == null
      ? appLocale.languageCode
      : '${appLocale.languageCode}-${appLocale.countryCode}';
  final controller = ErrorReportController(
    appInfo: ref.watch(appInfoProvider).requireValue,
    preferences: ref.watch(sharedPreferencesProvider).requireValue,
    stableDeviceId: ref.watch(stableDeviceIdServiceProvider),
    queue: ref.watch(errorReportQueueProvider),
    sender: ref.watch(errorReportSenderProvider),
    logPathResolver: ref.watch(logPathResolverProvider),
    coreService: ref.watch(zeonCoreServiceProvider),
    activeProfileReader: () => ref.read(activeProfileProvider.future),
    configOptionsSnapshotReader: () => ref.read(connectionRepositoryProvider).configOptionsSnapshot,
    locale: locale,
  );
  ref.onDispose(controller.dispose);
  return controller;
});
