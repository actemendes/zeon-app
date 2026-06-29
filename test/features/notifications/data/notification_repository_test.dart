import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/notifications/data/notification_api_data_source.dart';
import 'package:zeon/features/notifications/data/notification_local_data_source.dart';
import 'package:zeon/features/notifications/data/notification_repository.dart';
import 'package:zeon/features/notifications/model/notification_category.dart';
import 'package:zeon/features/notifications/model/notification_entity.dart';
import 'package:zeon/features/notifications/model/notification_priority.dart';
import 'package:zeon/features/notifications/model/notification_receipt.dart';
import 'package:zeon/features/notifications/service/notification_action_handler.dart';
import 'package:zeon/features/notifications/service/notification_receipt_queue.dart';
import 'package:zeon/features/notifications/service/system_notification_service.dart';

void main() {
  test('stores cursor and ETag, displays notifications, and flushes receipts', () async {
    final local = _FakeLocalDataSource()
      ..cursor = 'cursor-1'
      ..eTag = '"old"';
    final remote = _FakeRemoteDataSource()
      ..fetchResults.add(
        NotificationFetchResult.page(
          NotificationPage(
            notifications: [_notification(id: 'n-1')],
            nextCursor: 'cursor-2',
            eTag: '"new"',
          ),
        ),
      );
    final system = _FakeSystemNotificationService();
    final repository = _repository(local: local, remote: remote, system: system);

    final report = await repository.sync();

    expect(report.fetched, 1);
    expect(report.displayed, 1);
    expect(remote.seenCursors, ['cursor-1']);
    expect(remote.seenETags, ['"old"']);
    expect(local.cursor, 'cursor-2');
    expect(local.eTag, '"new"');
    expect(local.lastSuccessfulSync, isNotNull);
    expect(system.shown.map((notification) => notification.id), ['n-1']);
    expect(remote.sentBatches.single.map((receipt) => receipt.event), [
      NotificationReceiptEvent.fetched,
      NotificationReceiptEvent.displayed,
    ]);
    expect(local.receipts, isEmpty);
  });

  test('handles ETag 304 without resetting cursor or showing notifications', () async {
    final local = _FakeLocalDataSource()
      ..cursor = 'cursor-1'
      ..eTag = '"same"';
    final remote = _FakeRemoteDataSource()..fetchResults.add(NotificationFetchResult.notModified(eTag: '"same"'));
    final system = _FakeSystemNotificationService();
    final repository = _repository(local: local, remote: remote, system: system);

    final report = await repository.sync();

    expect(report.notModified, isTrue);
    expect(remote.seenCursors, ['cursor-1']);
    expect(remote.seenETags, ['"same"']);
    expect(local.cursor, 'cursor-1');
    expect(local.lastSuccessfulSync, isNotNull);
    expect(system.shown, isEmpty);
  });

  test('does not display duplicate notification ids twice', () async {
    final local = _FakeLocalDataSource();
    final remote = _FakeRemoteDataSource()
      ..fetchResults.add(
        NotificationFetchResult.page(
          NotificationPage(
            notifications: [_notification(id: 'same')],
            nextCursor: 'c-1',
            eTag: null,
          ),
        ),
      )
      ..fetchResults.add(
        NotificationFetchResult.page(
          NotificationPage(
            notifications: [_notification(id: 'same')],
            nextCursor: 'c-2',
            eTag: null,
          ),
        ),
      );
    final system = _FakeSystemNotificationService();
    final repository = _repository(local: local, remote: remote, system: system);

    await repository.sync();
    final second = await repository.sync();

    expect(system.shown.map((notification) => notification.id), ['same']);
    expect(second.skipped, 1);
  });

  test('filters expired notifications and disabled promotions', () async {
    final local = _FakeLocalDataSource();
    final remote = _FakeRemoteDataSource()
      ..fetchResults.add(
        NotificationFetchResult.page(
          NotificationPage(
            notifications: [
              _notification(id: 'expired', expiresAt: DateTime.utc(2025)),
              _notification(id: 'promo', category: NotificationCategory.promotion),
            ],
            nextCursor: null,
            eTag: null,
          ),
        ),
      );
    final system = _FakeSystemNotificationService();
    final repository = _repository(
      local: local,
      remote: remote,
      system: system,
      categoryEnabled: (category) => category != NotificationCategory.promotion,
    );

    final report = await repository.sync();

    expect(report.fetched, 2);
    expect(report.skipped, 2);
    expect(system.shown, isEmpty);
    expect(remote.sentBatches.single.map((receipt) => receipt.event), [
      NotificationReceiptEvent.fetched,
      NotificationReceiptEvent.fetched,
    ]);
  });

  test('queues failed receipt and skips display for invalid action_url', () async {
    final local = _FakeLocalDataSource();
    final remote = _FakeRemoteDataSource()
      ..fetchResults.add(
        NotificationFetchResult.page(
          NotificationPage(
            notifications: [_notification(id: 'bad-action', actionUrl: 'file:///tmp/bad')],
            nextCursor: null,
            eTag: null,
          ),
        ),
      );
    final system = _FakeSystemNotificationService();
    final repository = _repository(local: local, remote: remote, system: system);

    final report = await repository.sync();

    expect(report.failed, 1);
    expect(await local.wasShown('bad-action'), isTrue);
    expect(system.shown, isEmpty);
    expect(remote.sentBatches.single.map((receipt) => receipt.event), [
      NotificationReceiptEvent.fetched,
      NotificationReceiptEvent.failed,
    ]);
    expect(remote.sentBatches.single.last.errorCode, 'invalid_action_url');
  });

  test('reports system notification failure reason', () async {
    final local = _FakeLocalDataSource();
    final remote = _FakeRemoteDataSource()
      ..fetchResults.add(
        NotificationFetchResult.page(
          NotificationPage(notifications: [_notification(id: 'windows-fallback')], nextCursor: null, eTag: null),
        ),
      );
    final system = _FakeSystemNotificationService()
      ..result = const SystemNotificationShowResult(
        displayed: false,
        fallbackUsed: true,
        errorCode: 'windows_uac_disabled',
      );
    final repository = _repository(local: local, remote: remote, system: system);

    final report = await repository.sync();

    expect(report.displayed, 0);
    expect(report.failed, 1);
    expect(report.lastErrorCode, 'windows_uac_disabled');
    expect(await local.wasShown('windows-fallback'), isTrue);
    expect(remote.sentBatches.single.map((receipt) => receipt.event), [
      NotificationReceiptEvent.fetched,
      NotificationReceiptEvent.failed,
    ]);
    expect(remote.sentBatches.single.last.errorCode, 'windows_uac_disabled');
  });

  test('counts in-app fallback as displayed notification', () async {
    final local = _FakeLocalDataSource();
    final remote = _FakeRemoteDataSource()
      ..fetchResults.add(
        NotificationFetchResult.page(
          NotificationPage(notifications: [_notification(id: 'in-app-fallback')], nextCursor: null, eTag: null),
        ),
      );
    final system = _FakeSystemNotificationService()
      ..result = const SystemNotificationShowResult(displayed: true, fallbackUsed: true);
    final repository = _repository(local: local, remote: remote, system: system);

    final report = await repository.sync();

    expect(report.displayed, 1);
    expect(report.fallbackDisplayed, 1);
    expect(report.failed, 0);
    expect(remote.sentBatches.single.map((receipt) => receipt.event), [
      NotificationReceiptEvent.fetched,
      NotificationReceiptEvent.displayed,
    ]);
  });

  test('keeps receipts offline and retries them on the next successful sync', () async {
    final local = _FakeLocalDataSource();
    final remote = _FakeRemoteDataSource()
      ..throwOnSendReceipts = true
      ..fetchResults.add(
        NotificationFetchResult.page(
          NotificationPage(notifications: [_notification(id: 'offline')], nextCursor: null, eTag: null),
        ),
      );
    final repository = _repository(local: local, remote: remote, system: _FakeSystemNotificationService());

    await repository.sync();

    expect(local.receipts, hasLength(2));
    expect(remote.sendAttempts, 1);

    remote
      ..throwOnSendReceipts = false
      ..fetchResults.add(NotificationFetchResult.notModified());
    await repository.sync();

    expect(remote.sendAttempts, 2);
    expect(remote.sentBatches.single.map((receipt) => receipt.notificationId), ['offline', 'offline']);
    expect(local.receipts, isEmpty);
  });

  test('does not reset cursor after a temporary fetch failure', () async {
    final local = _FakeLocalDataSource()..cursor = 'stable-cursor';
    final remote = _FakeRemoteDataSource()..fetchError = const NotificationApiException('offline');
    final repository = _repository(local: local, remote: remote, system: _FakeSystemNotificationService());

    await expectLater(repository.sync(), throwsA(isA<NotificationApiException>()));

    expect(local.cursor, 'stable-cursor');
    expect(local.lastSuccessfulSync, isNull);
  });

  test('marks opened receipts and opens validated action_url on notification click', () async {
    final local = _FakeLocalDataSource();
    final remote = _FakeRemoteDataSource();
    final actionHandler = _FakeActionHandler();
    final repository = _repository(
      local: local,
      remote: remote,
      system: _FakeSystemNotificationService(),
      actionHandler: actionHandler,
    );

    await repository.handleTap(const NotificationActionPayload(notificationId: 'opened', actionUrl: 'zeon://test'));

    expect(local.openedIds, contains('opened'));
    expect(actionHandler.openedUrls, ['zeon://test']);
    expect(remote.sentBatches.single.map((receipt) => receipt.event), [NotificationReceiptEvent.opened]);
  });
}

NotificationRepository _repository({
  required _FakeLocalDataSource local,
  required _FakeRemoteDataSource remote,
  required _FakeSystemNotificationService system,
  bool Function() notificationsEnabled = _enabled,
  bool Function(NotificationCategory category) categoryEnabled = _categoryEnabled,
  NotificationActionHandler? actionHandler,
}) {
  return NotificationRepositoryImpl(
    apiDataSource: remote,
    localDataSource: local,
    receiptQueue: NotificationReceiptQueue(localDataSource: local, apiDataSource: remote),
    systemNotificationService: system,
    actionHandler: actionHandler ?? NotificationActionHandler(),
    notificationsEnabled: notificationsEnabled,
    categoryEnabled: categoryEnabled,
  );
}

bool _enabled() => true;

bool _categoryEnabled(NotificationCategory category) => true;

NotificationEntity _notification({
  required String id,
  NotificationCategory category = NotificationCategory.system,
  NotificationPriority priority = NotificationPriority.normal,
  String? actionUrl = 'https://zeon.example/notice',
  DateTime? expiresAt,
}) {
  return NotificationEntity(
    id: id,
    category: category,
    priority: priority,
    title: 'Title $id',
    body: 'Body $id',
    actionUrl: actionUrl,
    publishedAt: DateTime.utc(2026),
    expiresAt: expiresAt,
  );
}

class _StoredNotification {
  _StoredNotification(this.notification);

  NotificationEntity notification;
  DateTime? displayedAt;
  DateTime? openedAt;
}

class _FakeLocalDataSource implements NotificationLocalDataSource {
  String? cursor;
  String? eTag;
  DateTime? lastSuccessfulSync;
  final notifications = <String, _StoredNotification>{};
  final receipts = <PendingNotificationReceipt>[];
  final openedIds = <String>[];
  var _nextReceiptId = 1;

  @override
  Future<String?> getCursor() async => cursor;

  @override
  Future<void> setCursor(String? cursor) async => this.cursor = cursor;

  @override
  Future<String?> getETag() async => eTag;

  @override
  Future<void> setETag(String? eTag) async => this.eTag = eTag;

  @override
  Future<DateTime?> getLastSuccessfulSync() async => lastSuccessfulSync;

  @override
  Future<void> setLastSuccessfulSync(DateTime value) async => lastSuccessfulSync = value;

  @override
  Future<void> upsertNotification(NotificationEntity notification, DateTime fetchedAt) async {
    final stored = notifications[notification.id] ?? _StoredNotification(notification);
    stored.notification = notification;
    notifications[notification.id] = stored;
  }

  @override
  Future<bool> wasShown(String notificationId) async => notifications[notificationId]?.displayedAt != null;

  @override
  Future<void> markShown(String notificationId, DateTime shownAt) async {
    final stored = notifications[notificationId] ?? _StoredNotification(_notification(id: notificationId));
    stored.displayedAt = shownAt;
    notifications[notificationId] = stored;
  }

  @override
  Future<void> markOpened(String notificationId, DateTime openedAt) async {
    final stored = notifications[notificationId] ?? _StoredNotification(_notification(id: notificationId));
    stored.openedAt = openedAt;
    notifications[notificationId] = stored;
    openedIds.add(notificationId);
  }

  @override
  Future<void> enqueueReceipt(PendingNotificationReceipt receipt) async {
    receipts.add(
      PendingNotificationReceipt(
        localId: receipt.localId ?? _nextReceiptId++,
        notificationId: receipt.notificationId,
        event: receipt.event,
        occurredAt: receipt.occurredAt,
        errorCode: receipt.errorCode,
      ),
    );
  }

  @override
  Future<List<PendingNotificationReceipt>> getPendingReceipts({int limit = 100}) async {
    return receipts.take(limit).toList(growable: false);
  }

  @override
  Future<void> deleteReceipts(List<int> localIds) async {
    receipts.removeWhere((receipt) => localIds.contains(receipt.localId));
  }
}

class _FakeRemoteDataSource implements NotificationRemoteDataSource {
  final fetchResults = <NotificationFetchResult>[];
  final seenCursors = <String?>[];
  final seenETags = <String?>[];
  final sentBatches = <List<PendingNotificationReceipt>>[];
  Object? fetchError;
  bool throwOnSendReceipts = false;
  int sendAttempts = 0;

  @override
  Future<NotificationFetchResult> fetch({
    String? cursor,
    String? eTag,
    int limit = NotificationApiDataSource.defaultLimit,
  }) async {
    seenCursors.add(cursor);
    seenETags.add(eTag);
    final error = fetchError;
    if (error != null) throw error;
    if (fetchResults.isEmpty) return NotificationFetchResult.notModified(eTag: eTag);
    return fetchResults.removeAt(0);
  }

  @override
  Future<void> sendReceipts(List<PendingNotificationReceipt> receipts) async {
    sendAttempts++;
    if (throwOnSendReceipts) {
      throw const NotificationApiException('receipts_offline');
    }
    sentBatches.add(List<PendingNotificationReceipt>.of(receipts));
  }
}

class _FakeSystemNotificationService implements SystemNotificationService {
  final shown = <NotificationEntity>[];
  NotificationTapCallback? onTap;
  SystemNotificationShowResult result = const SystemNotificationShowResult(displayed: true, fallbackUsed: false);

  @override
  Future<void> initialize({NotificationTapCallback? onTap}) async => this.onTap = onTap;

  @override
  Future<bool?> requestPermission() async => true;

  @override
  Future<SystemNotificationShowResult> show(NotificationEntity notification) async {
    shown.add(notification);
    return result;
  }

  @override
  Future<SystemNotificationShowResult> showTestNotification() async => result;
}

class _FakeActionHandler extends NotificationActionHandler {
  final openedUrls = <String?>[];

  @override
  Future<bool> open(String? rawUrl) async {
    openedUrls.add(rawUrl);
    return true;
  }
}
