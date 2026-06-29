import 'package:zeon/features/notifications/model/notification_category.dart';
import 'package:zeon/features/notifications/model/notification_priority.dart';

class NotificationEntity {
  const NotificationEntity({
    required this.id,
    required this.category,
    required this.priority,
    required this.title,
    required this.body,
    required this.actionUrl,
    required this.publishedAt,
    required this.expiresAt,
  });

  final String id;
  final NotificationCategory category;
  final NotificationPriority priority;
  final String title;
  final String body;
  final String? actionUrl;
  final DateTime publishedAt;
  final DateTime? expiresAt;

  bool isExpired(DateTime now) {
    final expiry = expiresAt;
    return expiry != null && !expiry.toUtc().isAfter(now.toUtc());
  }

  static NotificationEntity? tryParse(Map<String, dynamic> json) {
    final id = _firstNonEmpty([json['id'], json['notification_id'], json['notificationId']]);
    final category = NotificationCategory.tryParse(json['category']?.toString());
    final priority = NotificationPriority.tryParse(json['priority']?.toString()) ?? NotificationPriority.normal;
    final title = _boundedText(json['title'], 160);
    final body = _boundedText(json['body'], 4000);
    final publishedAt = _parseDateTime(
      _firstNonEmpty([json['published_at'], json['publishedAt'], json['publish_at'], json['publishAt']]),
    );
    final expiresAt = _parseDateTime(_firstNonEmpty([json['expires_at'], json['expiresAt']]));
    final actionUrl = _boundedNullableText(_firstNonEmpty([json['action_url'], json['actionUrl']]), 2048);

    if (id == null || category == null || title == null || body == null || publishedAt == null) {
      return null;
    }

    return NotificationEntity(
      id: id,
      category: category,
      priority: priority,
      title: title,
      body: body,
      actionUrl: actionUrl,
      publishedAt: publishedAt,
      expiresAt: expiresAt,
    );
  }
}

class NotificationPage {
  const NotificationPage({required this.notifications, required this.nextCursor, required this.eTag});

  final List<NotificationEntity> notifications;
  final String? nextCursor;
  final String? eTag;

  // ignore: prefer_constructors_over_static_methods
  static NotificationPage parse(dynamic rawBody, {String? eTag}) {
    final body = _unwrapEnvelope(rawBody);
    final list = _extractList(body);
    final cursor = body is Map<String, dynamic>
        ? _firstNonEmpty([body['next_cursor'], body['nextCursor'], body['cursor']])
        : null;

    return NotificationPage(
      notifications: [
        for (final item in list)
          if (item is Map) NotificationEntity.tryParse(Map<String, dynamic>.from(item)),
      ].whereType<NotificationEntity>().toList(growable: false),
      nextCursor: cursor,
      eTag: eTag,
    );
  }
}

dynamic _unwrapEnvelope(dynamic rawBody) {
  if (rawBody is Map) {
    final map = Map<String, dynamic>.from(rawBody);
    if (map.containsKey('ok') && map.containsKey('data')) {
      return map['data'];
    }
    return map;
  }
  return rawBody;
}

List<dynamic> _extractList(dynamic body) {
  if (body is List) return body;
  if (body is Map<String, dynamic>) {
    final candidates = [body['notifications'], body['items'], body['data']];
    for (final candidate in candidates) {
      if (candidate is List) return candidate;
    }
  }
  return const [];
}

String? _firstNonEmpty(List<dynamic> values) {
  for (final value in values) {
    final text = value?.toString().trim();
    if (text != null && text.isNotEmpty && text.toLowerCase() != 'null') return text;
  }
  return null;
}

String? _boundedText(dynamic value, int maxLength) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) return null;
  return text.length > maxLength ? text.substring(0, maxLength) : text;
}

String? _boundedNullableText(String? value, int maxLength) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  return text.length > maxLength ? text.substring(0, maxLength) : text;
}

DateTime? _parseDateTime(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return DateTime.tryParse(value.trim())?.toUtc();
}
