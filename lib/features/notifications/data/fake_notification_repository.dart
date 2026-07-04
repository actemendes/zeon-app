import 'package:zeon/features/notifications/data/notification_repository.dart';
import 'package:zeon/features/notifications/model/notification_category.dart';
import 'package:zeon/features/notifications/model/notification_entity.dart';
import 'package:zeon/features/notifications/model/notification_priority.dart';
import 'package:zeon/features/notifications/service/system_notification_service.dart';

class FakeNotificationRepository implements NotificationRepository {
  FakeNotificationRepository({SystemNotificationService? systemNotificationService})
    : _systemNotificationService = systemNotificationService;

  final SystemNotificationService? _systemNotificationService;
  DateTime? lastSync;
  int syncCount = 0;
  final openedNotificationIds = <String>[];

  @override
  Future<void> initializeSystemNotifications() async {}

  @override
  Future<NotificationSyncReport> sync({bool manual = false}) async {
    syncCount++;
    lastSync = DateTime.now().toUtc();
    return const NotificationSyncReport(fetched: 1, displayed: 1);
  }

  @override
  Future<void> handleTap(NotificationActionPayload payload) async {
    openedNotificationIds.add(payload.notificationId);
  }

  @override
  Future<DateTime?> lastSuccessfulSync() async => lastSync;

  @override
  Future<SystemNotificationShowResult> showDebugNotification() {
    final service = _systemNotificationService;
    if (service != null) {
      return service.show(_debugNotification());
    }
    return Future.value(const SystemNotificationShowResult(displayed: true, fallbackUsed: false));
  }

  NotificationEntity _debugNotification() {
    return NotificationEntity(
      id: 'fake-debug',
      category: NotificationCategory.system,
      priority: NotificationPriority.normal,
      title: 'ZEON fake notification',
      body: 'Fake notification repository is active.',
      actionUrl: 'zeon://notifications/fake',
      publishedAt: DateTime.now().toUtc(),
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );
  }
}
