enum NotificationReceiptEvent {
  fetched('fetched'),
  displayed('displayed'),
  opened('opened'),
  dismissed('dismissed'),
  failed('failed');

  const NotificationReceiptEvent(this.wireName);

  final String wireName;
}

class PendingNotificationReceipt {
  const PendingNotificationReceipt({
    required this.notificationId,
    required this.event,
    required this.occurredAt,
    required this.errorCode,
    this.localId,
  });

  final int? localId;
  final String notificationId;
  final NotificationReceiptEvent event;
  final DateTime occurredAt;
  final String? errorCode;

  Map<String, dynamic> toJson() => {
    'notification_id': notificationId,
    'event': event.wireName,
    'occurred_at': occurredAt.toUtc().toIso8601String(),
    if (errorCode != null && errorCode!.isNotEmpty) 'error_code': errorCode,
  };
}
