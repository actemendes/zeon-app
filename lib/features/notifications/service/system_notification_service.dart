import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/features/notifications/model/notification_category.dart';
import 'package:hiddify/features/notifications/model/notification_entity.dart';
import 'package:hiddify/features/notifications/model/notification_priority.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hiddify/utils/windows_privilege_utils.dart';

typedef NotificationTapCallback = Future<void> Function(NotificationActionPayload payload);

abstract interface class SystemNotificationService {
  Future<void> initialize({NotificationTapCallback? onTap});
  Future<bool?> requestPermission();
  Future<SystemNotificationShowResult> show(NotificationEntity notification);
  Future<SystemNotificationShowResult> showTestNotification();
}

class SystemNotificationServiceImpl implements SystemNotificationService {
  SystemNotificationServiceImpl({FlutterLocalNotificationsPlugin? plugin, InAppNotificationController? fallback})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
      _fallback = fallback;

  static const windowsAppUserModelId = 'ZEON.ZEON';
  static const windowsActivatorGuid = '6f903538-42b1-4596-a479-bb779f21a65d';

  final FlutterLocalNotificationsPlugin _plugin;
  final InAppNotificationController? _fallback;
  bool _initialized = false;
  NotificationTapCallback? _onTap;

  @override
  Future<void> initialize({NotificationTapCallback? onTap}) async {
    _onTap = onTap ?? _onTap;
    if (_initialized) return;

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_logo'),
        windows: WindowsInitializationSettings(
          appName: 'ZEON',
          appUserModelId: windowsAppUserModelId,
          guid: windowsActivatorGuid,
        ),
      ),
      onDidReceiveNotificationResponse: _handleNotificationResponse,
    );
    await _createAndroidChannels();
    _initialized = true;

    final details = await _plugin.getNotificationAppLaunchDetails();
    final response = details?.notificationResponse;
    if (details?.didNotificationLaunchApp == true && response != null) {
      scheduleMicrotask(() => _handleNotificationResponse(response));
    }
  }

  @override
  Future<bool?> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      return android.requestNotificationsPermission();
    }
    return null;
  }

  @override
  Future<SystemNotificationShowResult> show(NotificationEntity notification) async {
    await initialize();
    if (PlatformUtils.isWindows && isWindowsProcessElevated() == true) {
      final fallbackDisplayed = _showInAppFallback(notification);
      final errorCode = isWindowsUacEnabled() == false ? 'windows_uac_disabled' : 'windows_elevated';
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
        notificationDetails: notificationDetailsFor(notification),
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
  Future<SystemNotificationShowResult> showTestNotification() {
    return show(
      NotificationEntity(
        id: 'debug-${DateTime.now().microsecondsSinceEpoch}',
        category: NotificationCategory.system,
        priority: NotificationPriority.normal,
        title: 'ZEON test notification',
        body: 'System notification diagnostics are working.',
        actionUrl: 'zeon://notifications/test',
        publishedAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      ),
    );
  }

  Future<void> _createAndroidChannels() async {
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    for (final category in NotificationCategory.values) {
      await android.createNotificationChannel(androidChannelForCategory(category));
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

NotificationDetails notificationDetailsFor(NotificationEntity notification) {
  final channel = androidChannelForCategory(notification.category);
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
    windows: WindowsNotificationDetails(
      subtitle: notification.category.wireName,
      duration: notification.priority == NotificationPriority.low
          ? WindowsNotificationDuration.short
          : WindowsNotificationDuration.long,
      timestamp: notification.publishedAt.toLocal(),
    ),
  );
}

AndroidNotificationChannel androidChannelForCategory(NotificationCategory category) {
  return switch (category) {
    NotificationCategory.alert => const AndroidNotificationChannel(
      'zeon_alerts',
      'Важные уведомления',
      description: 'Важные сообщения и предупреждения',
      importance: Importance.high,
    ),
    NotificationCategory.system => const AndroidNotificationChannel(
      'zeon_system',
      'Системные уведомления',
      description: 'Системные сообщения приложения',
    ),
    NotificationCategory.promotion => const AndroidNotificationChannel(
      'zeon_promotions',
      'Акции и предложения',
      description: 'Акции, предложения и промо-сообщения',
      importance: Importance.low,
    ),
    NotificationCategory.news => const AndroidNotificationChannel(
      'zeon_news',
      'Новости',
      description: 'Новости сервиса и продукта',
    ),
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
