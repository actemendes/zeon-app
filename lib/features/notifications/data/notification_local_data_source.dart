import 'package:drift/drift.dart';
import 'package:zeon/core/db/db.dart';
import 'package:zeon/features/notifications/model/notification_category.dart';
import 'package:zeon/features/notifications/model/notification_entity.dart';
import 'package:zeon/features/notifications/model/notification_priority.dart';
import 'package:zeon/features/notifications/model/notification_receipt.dart';

abstract interface class NotificationLocalDataSource {
  Future<String?> getCursor();
  Future<void> setCursor(String? cursor);
  Future<String?> getETag();
  Future<void> setETag(String? eTag);
  Future<DateTime?> getLastSuccessfulSync();
  Future<void> setLastSuccessfulSync(DateTime value);
  Future<void> upsertNotification(NotificationEntity notification, DateTime fetchedAt);
  Future<bool> wasShown(String notificationId);
  Future<void> markShown(String notificationId, DateTime shownAt);
  Future<void> markOpened(String notificationId, DateTime openedAt);
  Future<void> enqueueReceipt(PendingNotificationReceipt receipt);
  Future<List<PendingNotificationReceipt>> getPendingReceipts({int limit = 100});
  Future<void> deleteReceipts(List<int> localIds);
}

class NotificationDao extends DatabaseAccessor<Db> implements NotificationLocalDataSource {
  NotificationDao(super.db);

  static const _cursorKey = 'cursor';
  static const _eTagKey = 'etag';
  static const _lastSuccessfulSyncKey = 'last_successful_sync';

  @override
  Future<String?> getCursor() => _getState(_cursorKey);

  @override
  Future<void> setCursor(String? cursor) => _setState(_cursorKey, cursor);

  @override
  Future<String?> getETag() => _getState(_eTagKey);

  @override
  Future<void> setETag(String? eTag) => _setState(_eTagKey, eTag);

  @override
  Future<DateTime?> getLastSuccessfulSync() async {
    final value = await _getState(_lastSuccessfulSyncKey);
    if (value == null || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  @override
  Future<void> setLastSuccessfulSync(DateTime value) =>
      _setState(_lastSuccessfulSyncKey, value.toUtc().toIso8601String());

  @override
  Future<void> upsertNotification(NotificationEntity notification, DateTime fetchedAt) async {
    await into(db.remoteNotificationEntries).insertOnConflictUpdate(
      RemoteNotificationEntriesCompanion(
        id: Value(notification.id),
        category: Value(notification.category.wireName),
        priority: Value(notification.priority.wireName),
        title: Value(notification.title),
        body: Value(notification.body),
        actionUrl: Value(notification.actionUrl),
        publishedAt: Value(notification.publishedAt.toUtc()),
        expiresAt: Value(notification.expiresAt?.toUtc()),
        fetchedAt: Value(fetchedAt.toUtc()),
      ),
    );
  }

  @override
  Future<bool> wasShown(String notificationId) async {
    final entry =
        await (select(db.remoteNotificationEntries)
              ..where((tbl) => tbl.id.equals(notificationId))
              ..limit(1))
            .getSingleOrNull();
    return entry?.displayedAt != null;
  }

  @override
  Future<void> markShown(String notificationId, DateTime shownAt) async {
    await (update(db.remoteNotificationEntries)..where((tbl) => tbl.id.equals(notificationId))).write(
      RemoteNotificationEntriesCompanion(displayedAt: Value(shownAt.toUtc())),
    );
  }

  @override
  Future<void> markOpened(String notificationId, DateTime openedAt) async {
    await (update(db.remoteNotificationEntries)..where((tbl) => tbl.id.equals(notificationId))).write(
      RemoteNotificationEntriesCompanion(openedAt: Value(openedAt.toUtc())),
    );
  }

  @override
  Future<void> enqueueReceipt(PendingNotificationReceipt receipt) async {
    await into(db.notificationReceiptEntries).insert(
      NotificationReceiptEntriesCompanion.insert(
        notificationId: receipt.notificationId,
        event: receipt.event.wireName,
        occurredAt: receipt.occurredAt.toUtc(),
        errorCode: Value(receipt.errorCode),
      ),
    );
  }

  @override
  Future<List<PendingNotificationReceipt>> getPendingReceipts({int limit = 100}) async {
    final rows =
        await (select(db.notificationReceiptEntries)
              ..orderBy([(tbl) => OrderingTerm(expression: tbl.localId)])
              ..limit(limit.clamp(1, 100)))
            .get();
    return rows
        .map(
          (row) => PendingNotificationReceipt(
            localId: row.localId,
            notificationId: row.notificationId,
            event: NotificationReceiptEvent.values.firstWhere(
              (event) => event.wireName == row.event,
              orElse: () => NotificationReceiptEvent.failed,
            ),
            occurredAt: row.occurredAt.toUtc(),
            errorCode: row.errorCode,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> deleteReceipts(List<int> localIds) async {
    if (localIds.isEmpty) return;
    await (delete(db.notificationReceiptEntries)..where((tbl) => tbl.localId.isIn(localIds))).go();
  }

  Future<String?> _getState(String key) async {
    final row = await (select(db.notificationSyncStateEntries)..where((tbl) => tbl.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> _setState(String key, String? value) async {
    await into(db.notificationSyncStateEntries).insertOnConflictUpdate(
      NotificationSyncStateEntriesCompanion.insert(key: key, value: Value(value), updatedAt: DateTime.now().toUtc()),
    );
  }
}

extension StoredNotificationEntryX on StoredNotificationEntry {
  NotificationEntity? toEntity() {
    final category = NotificationCategory.tryParse(this.category);
    final priority = NotificationPriority.tryParse(this.priority);
    if (category == null || priority == null) return null;
    return NotificationEntity(
      id: id,
      category: category,
      priority: priority,
      title: title,
      body: body,
      actionUrl: actionUrl,
      publishedAt: publishedAt.toUtc(),
      expiresAt: expiresAt?.toUtc(),
    );
  }
}
