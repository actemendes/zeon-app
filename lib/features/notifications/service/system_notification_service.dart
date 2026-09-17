import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:zeon/core/notification/in_app_notification_controller.dart';
import 'package:zeon/features/notifications/model/notification_category.dart';
import 'package:zeon/features/notifications/model/notification_entity.dart';
import 'package:zeon/features/notifications/model/notification_priority.dart';
import 'package:zeon/gen/translations.g.dart';
import 'package:zeon/utils/custom_loggers.dart';
import 'package:zeon/utils/platform_utils.dart';
import 'package:zeon/utils/windows_privilege_utils.dart';

typedef NotificationTapCallback = Future<void> Function(NotificationActionPayload payload);

abstract interface class SystemNotificationService {
  Future<void> initialize({NotificationTapCallback? onTap});
  Future<bool?> requestPermission();
  Future<SystemNotificationShowResult> show(NotificationEntity notification);
  Future<SystemNotificationShowResult> showTestNotification();
}

class SystemNotificationServiceImpl with InfraLogger implements SystemNotificationService {
  SystemNotificationServiceImpl({
    FlutterLocalNotificationsPlugin? plugin,
    Future<Translations> Function()? translations,
    InAppNotificationController? fallback,
    Future<bool?> Function()? initializeSystemNotifications,
  }) : _translations = translations ?? (() => AppLocale.en.build()),
       _initializeSystemNotifications = initializeSystemNotifications,
       _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _fallback = fallback;

  static const windowsAppUserModelId = 'ZEON.ZEON';
  static const windowsActivatorGuid = '6f903538-42b1-4596-a479-bb779f21a65d';

  final FlutterLocalNotificationsPlugin _plugin;
  final Future<Translations> Function() _translations;
  final InAppNotificationController? _fallback;
  final Future<bool?> Function()? _initializeSystemNotifications;
  bool _initialized = false;
  bool _systemNotificationsAvailable = false;
  String? _initializationErrorCode;
  NotificationTapCallback? _onTap;

  @override
  Future<void> initialize({NotificationTapCallback? onTap}) async {
    _onTap = onTap ?? _onTap;
    if (_initialized) return;

    try {
      final initializer = _initializeSystemNotifications;
      final initialized = initializer != null
          ? await initializer()
          : await _plugin.initialize(
              settings: const InitializationSettings(
                android: AndroidInitializationSettings('ic_stat_logo'),
                iOS: DarwinInitializationSettings(),
                macOS: DarwinInitializationSettings(),
                windows: WindowsInitializationSettings(
                  appName: 'ZEON',
                  appUserModelId: windowsAppUserModelId,
                  guid: windowsActivatorGuid,
                ),
              ),
              onDidReceiveNotificationResponse: _handleNotificationResponse,
            );
      if (initialized != true) {
        _initializationErrorCode = PlatformUtils.isWindows
            ? 'windows_notification_init_failed'
            : 'system_notification_init_failed';
        return;
      }
      await _createAndroidChannels();
      _systemNotificationsAvailable = true;

      final details = await _plugin.getNotificationAppLaunchDetails();
      final response = details?.notificationResponse;
      if (details?.didNotificationLaunchApp == true && response != null) {
        scheduleMicrotask(() => _handleNotificationResponse(response));
      }
    } catch (error, stackTrace) {
      _initializationErrorCode = PlatformUtils.isWindows ? 'windows_notification_init_failed' : _errorCode(error);
      loggy.warning('system notification initialization failed; using in-app fallback', error, stackTrace);
    } finally {
      _initialized = true;
    }
  }

  @override
  Future<bool?> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      return android.requestNotificationsPermission();
    }
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      return ios.requestPermissions(alert: true, badge: true, sound: true);
    }
    final macos = _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
    if (macos != null) {
      return macos.requestPermissions(alert: true, badge: true, sound: true);
    }
    return null;
  }

  @override
  Future<SystemNotificationShowResult> show(NotificationEntity notification) async {
    await initialize();
    if (!_systemNotificationsAvailable || (PlatformUtils.isWindows && isWindowsProcessElevated() == true)) {
      final fallbackDisplayed = _showInAppFallback(notification);
      final errorCode = !_systemNotificationsAvailable
          ? (_initializationErrorCode ?? 'system_notification_init_failed')
          : (isWindowsUacEnabled() == false ? 'windows_uac_disabled' : 'windows_elevated');
      return SystemNotificationShowResult(
        displayed: fallbackDisplayed,
        fallbackUsed: true,
        errorCode: fallbackDisplayed ? null : errorCode,
      );
    }

    try {
      await _plugin.show(
        id: notificationSystemId(notification.id),
        title: _trimForDisplay(notification.title, 160),
        body: _trimForDisplay(notification.body, PlatformUtils.isWindows ? 600 : 1200),
        notificationDetails: notificationDetailsFor(notification, translations: await _translations()),
        payload: jsonEncode({'notification_id': notification.id, 'action_url': notification.actionUrl}),
      );
      return const SystemNotificationShowResult(displayed: true, fallbackUsed: false);
    } catch (e) {
      final fallbackDisplayed = _showInAppFallback(notification);
      return SystemNotificationShowResult(
        displayed: fallbackDisplayed,
        fallbackUsed: true,
        errorCode: fallbackDisplayed ? null : _errorCode(e),
      );
    }
  }

  @override
  Future<SystemNotificationShowResult> showTestNotification() async {
    final t = await _translations();
    return show(
      NotificationEntity(
        id: 'debug-${DateTime.now().microsecondsSinceEpoch}',
        category: NotificationCategory.system,
        priority: NotificationPriority.normal,
        title: t.components.notifications.testTitle,
        body: t.components.notifications.testBody,
        actionUrl: 'zeon://notifications/test',
        publishedAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      ),
    );
  }

  Future<void> _createAndroidChannels() async {
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    final t = await _translations();
    for (final category in NotificationCategory.values) {
      await android.createNotificationChannel(androidChannelForCategory(category, translations: t));
    }
  }

  /// Updates names on the existing channels, preserving IDs and user settings.
  Future<void> refreshChannelNames() async {
    if (!_initialized || !_systemNotificationsAvailable) return;
    try {
      await _createAndroidChannels();
    } catch (error, stackTrace) {
      loggy.warning('notification channel localization failed', error, stackTrace);
    }
  }

  void _handleNotificationResponse(NotificationResponse response) {
    final payload = NotificationActionPayload.tryParse(response.payload);
    if (payload == null) return;
    final callback = _onTap;
    if (callback == null) return;
    unawaited(callback(payload));
  }

  bool _showInAppFallback(NotificationEntity notification) {
    final fallback = _fallback;
    if (fallback == null) return false;
    final item = fallback.showRemoteNotificationFallback(
      notificationId: notification.id,
      title: _trimForDisplay(notification.title, 160),
      body: _trimForDisplay(notification.body, 600),
      actionUrl: notification.actionUrl,
      onTap: () {
        final callback = _onTap;
        if (callback == null) return;
        unawaited(
          callback(NotificationActionPayload(notificationId: notification.id, actionUrl: notification.actionUrl)),
        );
      },
    );
    return item != null;
  }
}

class SystemNotificationShowResult {
  const SystemNotificationShowResult({required this.displayed, required this.fallbackUsed, this.errorCode});

  final bool displayed;
  final bool fallbackUsed;
  final String? errorCode;
}

class NotificationActionPayload {
  const NotificationActionPayload({required this.notificationId, required this.actionUrl});

  final String notificationId;
  final String? actionUrl;

  static NotificationActionPayload? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final id = (decoded['notification_id'] ?? decoded['id'])?.toString().trim();
      if (id == null || id.isEmpty) return null;
      final actionUrl = decoded['action_url']?.toString().trim();
      return NotificationActionPayload(
        notificationId: id,
        actionUrl: actionUrl == null || actionUrl.isEmpty ? null : actionUrl,
      );
    } catch (_) {
      return null;
    }
  }
}

NotificationDetails notificationDetailsFor(NotificationEntity notification, {required Translations translations}) {
  final channel = androidChannelForCategory(notification.category, translations: translations);
  return NotificationDetails(
    android: AndroidNotificationDetails(
      channel.id,
      channel.name,
      channelDescription: channel.description,
      importance: androidImportanceFor(notification.priority),
      priority: androidPriorityFor(notification.priority),
      styleInformation: BigTextStyleInformation(_trimForDisplay(notification.body, 4000)),
      category: AndroidNotificationCategory.event,
    ),
    iOS: const DarwinNotificationDetails(),
    macOS: const DarwinNotificationDetails(),
    windows: WindowsNotificationDetails(
      subtitle: channel.name,
      duration: notification.priority == NotificationPriority.low
          ? WindowsNotificationDuration.short
          : WindowsNotificationDuration.long,
      timestamp: notification.publishedAt.toLocal(),
    ),
  );
}

AndroidNotificationChannel androidChannelForCategory(
  NotificationCategory category, {
  required Translations translations,
}) {
  final t = translations.components.notifications;
  return switch (category) {
    NotificationCategory.alert => AndroidNotificationChannel(
      'zeon_alerts',
      t.alerts,
      description: t.alertsDescription,
      importance: Importance.high,
    ),
    NotificationCategory.system => AndroidNotificationChannel(
      'zeon_system',
      t.system,
      description: t.systemDescription,
    ),
    NotificationCategory.promotion => AndroidNotificationChannel(
      'zeon_promotions',
      t.promotions,
      description: t.promotionsDescription,
      importance: Importance.low,
    ),
    NotificationCategory.news => AndroidNotificationChannel('zeon_news', t.news, description: t.newsDescription),
  };
}

Importance androidImportanceFor(NotificationPriority priority) {
  return switch (priority) {
    NotificationPriority.low => Importance.low,
    NotificationPriority.normal => Importance.defaultImportance,
    NotificationPriority.high => Importance.high,
    NotificationPriority.critical => Importance.high,
  };
}

Priority androidPriorityFor(NotificationPriority priority) {
  return switch (priority) {
    NotificationPriority.low => Priority.low,
    NotificationPriority.normal => Priority.defaultPriority,
    NotificationPriority.high => Priority.high,
    NotificationPriority.critical => Priority.high,
  };
}

int notificationSystemId(String notificationId) {
  final hash = notificationId.hashCode & 0x00ffffff;
  return 0x5a000000 | hash;
}

String _trimForDisplay(String value, int maxLength) {
  final normalized = value.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), ' ').trim();
  if (normalized.length <= maxLength) return normalized;
  return normalized.substring(0, maxLength);
}

String _errorCode(Object error) {
  final raw = error.runtimeType.toString().toLowerCase();
  return raw.isEmpty ? 'notification_show_failed' : raw;
}
