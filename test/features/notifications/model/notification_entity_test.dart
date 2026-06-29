import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/notifications/model/notification_category.dart';
import 'package:zeon/features/notifications/model/notification_entity.dart';
import 'package:zeon/features/notifications/model/notification_priority.dart';

void main() {
  group('NotificationPage.parse', () {
    test('parses notification response, cursor, and eTag', () {
      final page = NotificationPage.parse({
        'ok': true,
        'data': {
          'notifications': [
            {
              'notification_id': 'n-1',
              'category': 'alert',
              'priority': 'critical',
              'title': 'Title',
              'body': 'Body',
              'action_url': 'https://zeon.example/notice',
              'published_at': '2026-01-02T03:04:05Z',
              'expires_at': '2026-01-03T03:04:05Z',
            },
          ],
          'next_cursor': 'cursor-2',
        },
      }, eTag: '"etag-1"');

      expect(page.nextCursor, 'cursor-2');
      expect(page.eTag, '"etag-1"');
      expect(page.notifications, hasLength(1));
      expect(page.notifications.single.id, 'n-1');
      expect(page.notifications.single.category, NotificationCategory.alert);
      expect(page.notifications.single.priority, NotificationPriority.critical);
      expect(page.notifications.single.actionUrl, 'https://zeon.example/notice');
    });

    test('drops malformed items and defaults priority to normal', () {
      final page = NotificationPage.parse({
        'items': [
          {'id': 'n-2', 'category': 'system', 'title': 'Title', 'body': 'Body', 'publishedAt': '2026-01-02T03:04:05Z'},
          {'id': 'bad', 'category': 'unknown', 'title': 'Bad', 'body': 'Bad', 'published_at': '2026-01-02T03:04:05Z'},
        ],
      });

      expect(page.notifications, hasLength(1));
      expect(page.notifications.single.priority, NotificationPriority.normal);
    });
  });

  test('detects expired notifications on the client', () {
    final notification = NotificationEntity(
      id: 'expired',
      category: NotificationCategory.system,
      priority: NotificationPriority.normal,
      title: 'Expired',
      body: 'Expired',
      actionUrl: null,
      publishedAt: DateTime.utc(2026),
      expiresAt: DateTime.utc(2026, 1, 1, 12),
    );

    expect(notification.isExpired(DateTime.utc(2026, 1, 1, 12)), isTrue);
    expect(notification.isExpired(DateTime.utc(2026, 1, 1, 11, 59)), isFalse);
  });
}
