import 'package:zeon/features/notifications/data/notification_api_data_source.dart';
import 'package:zeon/features/notifications/data/notification_local_data_source.dart';
import 'package:zeon/features/notifications/model/notification_receipt.dart';

class NotificationReceiptQueue {
  NotificationReceiptQueue({
    required NotificationLocalDataSource localDataSource,
    required NotificationRemoteDataSource apiDataSource,
  }) : _localDataSource = localDataSource,
       _apiDataSource = apiDataSource;

  final NotificationLocalDataSource _localDataSource;
  final NotificationRemoteDataSource _apiDataSource;

  Future<void> enqueue({
    required String notificationId,
    required NotificationReceiptEvent event,
    DateTime? occurredAt,
    String? errorCode,
  }) {
    return _localDataSource.enqueueReceipt(
      PendingNotificationReceipt(
        notificationId: notificationId,
        event: event,
        occurredAt: occurredAt ?? DateTime.now().toUtc(),
        errorCode: _sanitizeErrorCode(errorCode),
      ),
    );
  }

  Future<void> flush() async {
    final receipts = await _localDataSource.getPendingReceipts();
    if (receipts.isEmpty) return;
    await _apiDataSource.sendReceipts(receipts);
    await _localDataSource.deleteReceipts(receipts.map((receipt) => receipt.localId).whereType<int>().toList());
  }
}

String? _sanitizeErrorCode(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  final normalized = value.toLowerCase().replaceAll(RegExp('[^a-z0-9_\\-]'), '_');
  return normalized.length > 80 ? normalized.substring(0, 80) : normalized;
}
