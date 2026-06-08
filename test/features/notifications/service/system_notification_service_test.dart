import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/notifications/model/notification_category.dart';
import 'package:hiddify/features/notifications/model/notification_entity.dart';
import 'package:hiddify/features/notifications/model/notification_priority.dart';
import 'package:hiddify/features/notifications/service/system_notification_service.dart';

void main() {
  test('maps Android notification channels by category', () {
    final alert = androidChannelForCategory(NotificationCategory.alert);
    final system = androidChannelForCategory(NotificationCategory.system);
    final promotion = androidChannelForCategory(NotificationCategory.promotion);
    final news = androidChannelForCategory(NotificationCategory.news);

    expect(alert.id, 'zeon_alerts');
    expect(alert.name, 'Важные уведомления');
    expect(system.id, 'zeon_system');
    expect(system.name, 'Системные уведомления');
    expect(promotion.id, 'zeon_promotions');
    expect(promotion.name, 'Акции и предложения');
    expect(news.id, 'zeon_news');
    expect(news.name, 'Новости');
  });

  test('maps Android priority conservatively', () {
    expect(androidImportanceFor(NotificationPriority.low), Importance.low);
    expect(androidImportanceFor(NotificationPriority.normal), Importance.defaultImportance);
    expect(androidImportanceFor(NotificationPriority.high), Importance.high);
    expect(androidImportanceFor(NotificationPriority.critical), Importance.high);
    expect(androidPriorityFor(NotificationPriority.critical), Priority.high);
  });

  test('builds platform notification details without using the VPN notification id', () {
    final notification = NotificationEntity(
      id: 'remote-id',
      category: NotificationCategory.news,
      priority: NotificationPriority.low,
      title: 'Title',
      body: 'Body',
      actionUrl: null,
      publishedAt: DateTime.utc(2026),
      expiresAt: null,
    );

    final details = notificationDetailsFor(notification);

    expect(notificationSystemId(notification.id), isNot(1));
    expect(details.android?.channelId, 'zeon_news');
    expect(details.android?.importance, Importance.low);
    expect(details.windows?.subtitle, 'news');
    expect(details.windows?.duration, WindowsNotificationDuration.short);
  });
}
