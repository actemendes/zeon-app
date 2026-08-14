import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/app_info/app_info_provider.dart';
import 'package:zeon/core/db/provider/db_providers.dart';
import 'package:zeon/core/http_client/http_client_provider.dart';
import 'package:zeon/core/localization/locale_preferences.dart';
import 'package:zeon/core/notification/in_app_notification_controller.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/notifications/data/notification_api_data_source.dart';
import 'package:zeon/features/notifications/data/notification_device_auth.dart';
import 'package:zeon/features/notifications/data/notification_local_data_source.dart';
import 'package:zeon/features/notifications/data/notification_repository.dart';
import 'package:zeon/features/notifications/service/notification_action_handler.dart';
import 'package:zeon/features/notifications/service/notification_polling_service.dart';
import 'package:zeon/features/notifications/service/notification_receipt_queue.dart';
import 'package:zeon/features/notifications/service/system_notification_service.dart';
import 'package:zeon/utils/platform_utils.dart';

final notificationLocalDataSourceProvider = Provider<NotificationLocalDataSource>((ref) {
  return NotificationDao(ref.watch(dbProvider));
});

final notificationDeviceAuthProvider = Provider<NotificationDeviceAuth>((ref) {
  return NotificationDeviceAuth(
    httpClient: ref.watch(httpClientProvider),
    preferences: ref.watch(sharedPreferencesProvider).requireValue,
  );
});

final notificationApiDataSourceProvider = Provider<NotificationApiDataSource>((ref) {
  final appInfo = ref.watch(appInfoProvider).requireValue;
  final appLocale = ref.watch(localePreferencesProvider);
  final locale = appLocale.countryCode == null
      ? appLocale.languageCode
      : '${appLocale.languageCode}-${appLocale.countryCode}';
  return NotificationApiDataSource(
    httpClient: ref.watch(httpClientProvider),
    deviceAuth: ref.watch(notificationDeviceAuthProvider),
    appVersion: appInfo.version,
    platform: notificationPlatformName(),
    locale: locale,
  );
});

final notificationReceiptQueueProvider = Provider<NotificationReceiptQueue>((ref) {
  return NotificationReceiptQueue(
    localDataSource: ref.watch(notificationLocalDataSourceProvider),
    apiDataSource: ref.watch(notificationApiDataSourceProvider),
  );
});

final notificationActionHandlerProvider = Provider<NotificationActionHandler>((ref) {
  return NotificationActionHandler();
});

final systemNotificationServiceProvider = Provider<SystemNotificationService>((ref) {
  return SystemNotificationServiceImpl(fallback: ref.watch(inAppNotificationControllerProvider));
});

final notificationRepositoryProvider = Provider<NotificationRepository>((ref) {
  return NotificationRepositoryImpl(
    apiDataSource: ref.watch(notificationApiDataSourceProvider),
    localDataSource: ref.watch(notificationLocalDataSourceProvider),
    receiptQueue: ref.watch(notificationReceiptQueueProvider),
    systemNotificationService: ref.watch(systemNotificationServiceProvider),
    actionHandler: ref.watch(notificationActionHandlerProvider),
    notificationsEnabled: () => notificationPollingSupported && ref.read(Preferences.remoteNotifications),
    categoryEnabled: (_) => true,
  );
});

final notificationPollingServiceProvider = Provider<NotificationPollingService>((ref) {
  final service = NotificationPollingService(
    repository: ref.watch(notificationRepositoryProvider),
    notificationsEnabled: () => notificationPollingSupported && ref.read(Preferences.remoteNotifications),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Remote polling currently has a production server and background-delivery
/// contract only on Android and Windows. Other platforms must not issue the
/// request: the server rejects their platform header with HTTP 400.
bool get notificationPollingSupported => PlatformUtils.isAndroid || PlatformUtils.isWindows;

final notificationLastSuccessfulSyncProvider = FutureProvider<DateTime?>((ref) {
  return ref.watch(notificationLocalDataSourceProvider).getLastSuccessfulSync();
});

String notificationPlatformName() {
  if (PlatformUtils.isAndroid) return 'android';
  if (PlatformUtils.isWindows) return 'windows';
  if (PlatformUtils.isIOS) return 'ios';
  if (PlatformUtils.isMacOS) return 'macos';
  if (PlatformUtils.isLinux) return 'linux';
  return 'unknown';
}
