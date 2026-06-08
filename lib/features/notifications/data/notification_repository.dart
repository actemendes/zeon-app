import 'package:dio/dio.dart';
import 'package:hiddify/features/notifications/data/notification_api_data_source.dart';
import 'package:hiddify/features/notifications/data/notification_local_data_source.dart';
import 'package:hiddify/features/notifications/model/notification_category.dart';
import 'package:hiddify/features/notifications/model/notification_receipt.dart';
import 'package:hiddify/features/notifications/service/notification_action_handler.dart';
import 'package:hiddify/features/notifications/service/notification_receipt_queue.dart';
import 'package:hiddify/features/notifications/service/system_notification_service.dart';
import 'package:hiddify/utils/custom_loggers.dart';

abstract interface class NotificationRepository {
  Future<void> initializeSystemNotifications();
  Future<NotificationSyncReport> sync({bool manual = false});
  Future<void> handleTap(NotificationActionPayload payload);
  Future<DateTime?> lastSuccessfulSync();
  Future<SystemNotificationShowResult> showDebugNotification();
}

class NotificationRepositoryImpl with InfraLogger implements NotificationRepository {
  NotificationRepositoryImpl({
    required NotificationRemoteDataSource apiDataSource,
    required NotificationLocalDataSource localDataSource,
    required NotificationReceiptQueue receiptQueue,
    required SystemNotificationService systemNotificationService,
    required NotificationActionHandler actionHandler,
    required bool Function() notificationsEnabled,
    required bool Function(NotificationCategory category) categoryEnabled,
  }) : _apiDataSource = apiDataSource,
       _localDataSource = localDataSource,
       _receiptQueue = receiptQueue,
       _systemNotificationService = systemNotificationService,
       _actionHandler = actionHandler,
       _notificationsEnabled = notificationsEnabled,
       _categoryEnabled = categoryEnabled;

  final NotificationRemoteDataSource _apiDataSource;
  final NotificationLocalDataSource _localDataSource;
  final NotificationReceiptQueue _receiptQueue;
  final SystemNotificationService _systemNotificationService;
  final NotificationActionHandler _actionHandler;
  final bool Function() _notificationsEnabled;
  final bool Function(NotificationCategory category) _categoryEnabled;

  @override
  Future<void> initializeSystemNotifications() {
    return _systemNotificationService.initialize(onTap: handleTap);
  }

  @override
  Future<NotificationSyncReport> sync({bool manual = false}) async {
    if (!_notificationsEnabled()) {
      return const NotificationSyncReport(disabled: true);
    }

    await _tryFlushReceipts();

    final cursor = await _localDataSource.getCursor();
    final eTag = await _localDataSource.getETag();
    final fetchResult = await _apiDataSource.fetch(cursor: cursor, eTag: eTag);
    final now = DateTime.now().toUtc();
    var fetched = 0;
    var displayed = 0;
    var fallbackDisplayed = 0;
    var skipped = 0;
    var failed = 0;
    String? lastErrorCode;

    if (fetchResult.notModified) {
      await _markSuccessfulSync(now, eTag: fetchResult.eTag);
      await _tryFlushReceipts();
      return const NotificationSyncReport(notModified: true);
    }

    final page = fetchResult.page;
    if (page == null) {
      throw const NotificationApiException('missing_notifications_page');
    }

    for (final notification in page.notifications) {
      fetched++;
      await _localDataSource.upsertNotification(notification, now);
      await _receiptQueue.enqueue(
        notificationId: notification.id,
        event: NotificationReceiptEvent.fetched,
        occurredAt: now,
      );

      if (notification.isExpired(now)) {
        skipped++;
        continue;
      }
      if (!_categoryEnabled(notification.category)) {
        skipped++;
        continue;
      }
      if (await _localDataSource.wasShown(notification.id)) {
        skipped++;
        continue;
      }

      if (!_actionHandler.isAllowed(notification.actionUrl) && notification.actionUrl != null) {
        lastErrorCode = 'invalid_action_url';
        await _localDataSource.markShown(notification.id, now);
        await _receiptQueue.enqueue(
          notificationId: notification.id,
          event: NotificationReceiptEvent.failed,
          occurredAt: now,
          errorCode: lastErrorCode,
        );
        failed++;
        continue;
      }

      final result = await _systemNotificationService.show(notification);
      await _localDataSource.markShown(notification.id, now);
      if (result.displayed) {
        displayed++;
        if (result.fallbackUsed) {
          fallbackDisplayed++;
        }
        await _receiptQueue.enqueue(
          notificationId: notification.id,
          event: NotificationReceiptEvent.displayed,
          occurredAt: now,
        );
      } else {
        failed++;
        lastErrorCode = result.errorCode ?? 'system_notification_failed';
        await _receiptQueue.enqueue(
          notificationId: notification.id,
          event: NotificationReceiptEvent.failed,
          occurredAt: now,
          errorCode: lastErrorCode,
        );
      }
    }

    if (page.nextCursor != null) {
      await _localDataSource.setCursor(page.nextCursor);
    }
    await _markSuccessfulSync(now, eTag: page.eTag);
    await _tryFlushReceipts();
    return NotificationSyncReport(
      fetched: fetched,
      displayed: displayed,
      fallbackDisplayed: fallbackDisplayed,
      skipped: skipped,
      failed: failed,
      lastErrorCode: lastErrorCode,
    );
  }

  @override
  Future<void> handleTap(NotificationActionPayload payload) async {
    final now = DateTime.now().toUtc();
    await _localDataSource.markOpened(payload.notificationId, now);
    await _receiptQueue.enqueue(
      notificationId: payload.notificationId,
      event: NotificationReceiptEvent.opened,
      occurredAt: now,
    );
    await _actionHandler.open(payload.actionUrl);
    await _tryFlushReceipts();
  }

  @override
  Future<DateTime?> lastSuccessfulSync() => _localDataSource.getLastSuccessfulSync();

  @override
  Future<SystemNotificationShowResult> showDebugNotification() => _systemNotificationService.showTestNotification();

  Future<void> _markSuccessfulSync(DateTime now, {String? eTag}) async {
    await _localDataSource.setLastSuccessfulSync(now);
    if (eTag != null && eTag.trim().isNotEmpty) {
      await _localDataSource.setETag(eTag);
    }
  }

  Future<void> _tryFlushReceipts() async {
    try {
      await _receiptQueue.flush();
    } on DioException catch (e, st) {
      loggy.debug('notification receipts flush deferred [type=${e.type.name}]', e, st);
    } catch (e, st) {
      loggy.debug('notification receipts flush deferred', e, st);
    }
  }
}

class NotificationSyncReport {
  const NotificationSyncReport({
    this.notModified = false,
    this.disabled = false,
    this.fetched = 0,
    this.displayed = 0,
    this.fallbackDisplayed = 0,
    this.skipped = 0,
    this.failed = 0,
    this.lastErrorCode,
  });

  final bool notModified;
  final bool disabled;
  final int fetched;
  final int displayed;
  final int fallbackDisplayed;
  final int skipped;
  final int failed;
  final String? lastErrorCode;
}
