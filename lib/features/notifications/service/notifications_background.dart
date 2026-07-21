import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:zeon/core/db/db.dart';
import 'package:zeon/core/http_client/dio_http_client.dart';
import 'package:zeon/features/notifications/data/notification_api_data_source.dart';
import 'package:zeon/features/notifications/data/notification_device_auth.dart';
import 'package:zeon/features/notifications/data/notification_local_data_source.dart';
import 'package:zeon/features/notifications/data/notification_repository.dart';
import 'package:zeon/features/notifications/service/notification_action_handler.dart';
import 'package:zeon/features/notifications/service/notification_polling_service.dart';
import 'package:zeon/features/notifications/service/notification_receipt_queue.dart';
import 'package:zeon/features/notifications/service/system_notification_service.dart';
import 'package:zeon/utils/platform_utils.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

@pragma('vm:entry-point')
void notificationWorkmanagerDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != NotificationPollingService.androidPeriodicTaskName) return true;
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return runNotificationsBackgroundSync();
  });
}

@pragma('vm:entry-point')
Future<bool> runNotificationsBackgroundSync() async {
  final preferences = await SharedPreferences.getInstance();
  if (!(preferences.getBool('remote_notifications') ?? true)) return true;

  final db = Db();
  try {
    final packageInfo = await PackageInfo.fromPlatform();
    final platform = PlatformUtils.isAndroid
        ? 'android'
        : PlatformUtils.isWindows
        ? 'windows'
        : 'unknown';
    final locale = PlatformDispatcher.instance.locale.toLanguageTag();
    final httpClient = DioHttpClient(
      timeout: const Duration(seconds: 8),
      userAgent: 'ZEON/${packageInfo.version} ($platform) like ClashMeta v2ray sing-box',
      debug: false,
    );
    // The worker runs in a separate isolate, so it cannot reuse the provider's
    // in-memory port. If the local VPN proxy is alive it is used exclusively;
    // otherwise the worker uses the ordinary network and retries next cycle.
    httpClient.setProxyPort(preferences.getInt('mixed-port') ?? 12334);
    final local = NotificationDao(db);
    final api = NotificationApiDataSource(
      httpClient: httpClient,
      deviceAuth: NotificationDeviceAuth(httpClient: httpClient, preferences: preferences),
      appVersion: packageInfo.version,
      platform: platform,
      locale: locale,
    );
    final receiptQueue = NotificationReceiptQueue(localDataSource: local, apiDataSource: api);
    final repository = NotificationRepositoryImpl(
      apiDataSource: api,
      localDataSource: local,
      receiptQueue: receiptQueue,
      systemNotificationService: SystemNotificationServiceImpl(),
      actionHandler: NotificationActionHandler(),
      notificationsEnabled: () => preferences.getBool('remote_notifications') ?? true,
      categoryEnabled: (_) => true,
    );
    await repository.sync();
    return true;
  } catch (_) {
    return false;
  } finally {
    await db.close();
  }
}
