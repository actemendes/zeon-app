import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/features/notifications/data/notification_api_data_source.dart';
import 'package:hiddify/features/notifications/data/notification_device_auth.dart';
import 'package:hiddify/features/notifications/data/notification_local_data_source.dart';
import 'package:hiddify/features/notifications/data/notification_repository.dart';
import 'package:hiddify/features/notifications/service/notification_action_handler.dart';
import 'package:hiddify/features/notifications/service/notification_polling_service.dart';
import 'package:hiddify/features/notifications/service/notification_receipt_queue.dart';
import 'package:hiddify/features/notifications/service/system_notification_service.dart';
import 'package:hiddify/utils/platform_utils.dart';
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
      userAgent: 'HiddifyNext/${packageInfo.version} ($platform) like ClashMeta v2ray sing-box',
      debug: false,
    );
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
