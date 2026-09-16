import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/notification/app_notice.dart';
import 'package:zeon/core/notification/app_notice_host.dart';
import 'package:zeon/core/notification/in_app_notification_controller.dart';
import 'package:zeon/core/router/dialog/widgets/custom_alert_dialog.dart';
import 'package:zeon/core/router/go_router/go_router_notifier.dart';
import 'package:zeon/core/theme/app_theme.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/features/notifications/model/notification_category.dart';
import 'package:zeon/features/notifications/model/notification_entity.dart';
import 'package:zeon/features/notifications/model/notification_priority.dart';
import 'package:zeon/features/notifications/service/system_notification_service.dart';
import 'package:zeon/gen/translations_ru.g.dart';
import 'package:zeon/utils/alerts.dart';

Future<AppNoticeController> mountNotices(
  WidgetTester tester, {
  AppNoticeController? controller,
  AppThemeMode mode = AppThemeMode.dark,
  bool reduced = false,
  double textScale = 1,
  Size? size,
  EdgeInsets insets = EdgeInsets.zero,
  EdgeInsets padding = EdgeInsets.zero,
  VoidCallback? onBackgroundTap,
}) async {
  final notices = controller ?? AppNoticeController();
  final theme = AppTheme(mode, 'Montserrat');
  await tester.pumpWidget(
    ProviderScope(
      overrides: [translationsProvider.overrideWith((ref) => TranslationsRu())],
      child: MaterialApp(
        navigatorKey: rootNavKey,
        debugShowCheckedModeBanner: false,
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: mode == AppThemeMode.light ? theme.lightTheme(null) : theme.darkTheme(null),
        builder: (context, child) => Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: size?.width,
            height: size?.height,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                size: size,
                textScaler: TextScaler.linear(textScale),
                disableAnimations: reduced,
                viewInsets: insets,
                viewPadding: padding,
              ),
              child: AppNoticeHost(controller: notices, child: child!),
            ),
          ),
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: TextButton(onPressed: onBackgroundTap ?? () {}, child: const Text('Фон приложения')),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    if (!identical(notices, appNoticeController)) notices.dispose();
  });
  return notices;
}

AppNotice localNotice(String title, {Duration duration = const Duration(seconds: 3), VoidCallback? onTap}) =>
    AppNotice(title: title, kind: AppNoticeKind.info, identity: title, duration: duration, onTap: onTap);

Future<void> finishMotion(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('without a mounted host fallback is not reported as delivered', (tester) async {
    final notices = AppNoticeController();
    final service = SystemNotificationServiceImpl(
      fallback: InAppNotificationController(notices: notices),
      initializeSystemNotifications: () async => false,
    );
    final result = await service.show(remoteNotification('no-host'));
    expect(result.displayed, isFalse);
    expect(result.fallbackUsed, isTrue);
    expect(notices.entries, isEmpty);
    notices.dispose();
  });

  testWidgets('100 distinct messages keep three entries and one readable card', (tester) async {
    var backgroundTaps = 0;
    final notices = await mountNotices(tester, onBackgroundTap: () => backgroundTaps++);
    notices.show(localNotice('First'));
    await finishMotion(tester);
    final height = tester.getSize(find.byType(AppNoticeCard)).height;
    for (var i = 0; i < 100; i++) {
      notices.show(localNotice('Message $i'));
    }
    await finishMotion(tester);
    expect(notices.entries.map((entry) => entry.notice.title), ['Message 99', 'Message 98', 'Message 97']);
    expect(find.byType(AppNoticeCard), findsOneWidget);
    expect(tester.getSize(find.byType(AppNoticeCard)).height, height);
    await tester.tap(find.text('Фон приложения'));
    expect(backgroundTaps, 1);
    await tester.tap(find.byTooltip('Закрыть'));
    await finishMotion(tester);
    expect(find.text('Message 98'), findsOneWidget);
  });

  testWidgets('identical errors merge; different diagnostic details stay distinct', (tester) async {
    final notices = await mountNotices(tester);
    final api = InAppNotificationController(notices: notices);
    for (var i = 0; i < 10; i++) {
      api.showErrorToast('Ошибка', diagnosticText: 'trace A');
    }
    await finishMotion(tester);
    expect(notices.entries.length, 1);
    expect(find.text('×10'), findsOneWidget);
    api.showErrorToast('Ошибка', diagnosticText: 'trace B');
    expect(notices.entries.length, 2);
    expect(notices.entries.first.count, 1);
  });

  testWidgets('close, tap and swipe preserve action ownership', (tester) async {
    final notices = await mountNotices(tester);
    var taps = 0;
    notices.show(localNotice('Tap', onTap: () => taps++));
    await finishMotion(tester);
    await tester.tap(find.text('Tap'));
    await finishMotion(tester);
    expect(taps, 1);
    notices.show(localNotice('Close', onTap: () => taps++));
    await finishMotion(tester);
    await tester.tap(find.byTooltip('Закрыть'));
    await finishMotion(tester);
    expect(taps, 1);
    notices.show(localNotice('Swipe', onTap: () => taps++));
    await finishMotion(tester);
    await tester.drag(find.byType(AppNoticeCard), const Offset(180, 0));
    await finishMotion(tester);
    expect(notices.entries, isEmpty);
    expect(taps, 1);
  });

  testWidgets('covered notices get their full interval when promoted', (tester) async {
    final notices = await mountNotices(tester, reduced: true);
    notices.show(localNotice('Old', duration: const Duration(milliseconds: 700)));
    notices.show(localNotice('New', duration: const Duration(milliseconds: 700)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 850));
    expect(notices.entries.single.notice.title, 'Old');
    await tester.pump(const Duration(milliseconds: 850));
    expect(notices.entries, isEmpty);
  });

  testWidgets('repeat restarts timer and interaction pauses expiry', (tester) async {
    final notices = await mountNotices(tester, reduced: true);
    final notice = localNotice('Read me', duration: const Duration(milliseconds: 600));
    notices.show(notice);
    await tester.pump(const Duration(milliseconds: 350));
    notices.show(notice);
    await tester.pump(const Duration(milliseconds: 350));
    expect(notices.entries.single.count, 2);
    notices.pause(AppNoticePause.focus, paused: true);
    await tester.pump(const Duration(milliseconds: 750));
    expect(notices.entries, hasLength(1));
    notices.pause(AppNoticePause.focus, paused: false);
    await tester.pump(const Duration(milliseconds: 750));
    expect(notices.entries, isEmpty);
  });

  testWidgets('host detach cancels timers and pending notifications', (tester) async {
    final notices = await mountNotices(tester);
    notices.show(localNotice('Detach', duration: const Duration(milliseconds: 100)));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
    expect(notices.entries, isEmpty);
    expect(notices.show(localNotice('No host')), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native init failure presents fallback and forwards original payload once', (tester) async {
    final notices = await mountNotices(tester);
    final opened = <NotificationActionPayload>[];
    final service = SystemNotificationServiceImpl(
      fallback: InAppNotificationController(notices: notices),
      initializeSystemNotifications: () async => false,
    );
    await service.initialize(onTap: (payload) async => opened.add(payload));
    final result = await service.show(remoteNotification('id-one'));
    await finishMotion(tester);
    expect(result.displayed, isTrue);
    expect(result.fallbackUsed, isTrue);
    expect(result.errorCode, isNull);
    expect(find.text('Открыть'), findsOneWidget);
    expect(notices.entries.single.notice.duration, const Duration(seconds: 12));
    await tester.tap(find.text('Открыть'));
    await finishMotion(tester);
    expect(opened.single.notificationId, 'id-one');
    expect(opened.single.actionUrl, 'zeon://notifications/test');
    expect(notices.entries, isEmpty);
  });

  testWidgets('native init exception falls back; matching text with distinct IDs does not merge', (tester) async {
    final notices = await mountNotices(tester);
    final service = SystemNotificationServiceImpl(
      fallback: InAppNotificationController(notices: notices),
      initializeSystemNotifications: () async => throw StateError('forced test failure'),
    );
    expect((await service.show(remoteNotification('id-a'))).displayed, isTrue);
    expect((await service.show(remoteNotification('id-b'))).displayed, isTrue);
    expect(notices.entries, hasLength(2));
    expect((await service.show(remoteNotification('id-b'))).displayed, isTrue);
    expect(notices.entries, hasLength(2));
    expect(notices.entries.first.count, 2);
    await finishMotion(tester);
  });

  testWidgets('native show exception uses the same remote fallback', (tester) async {
    final notices = await mountNotices(tester);
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'show') throw PlatformException(code: 'forced_show_failure');
      if (call.method == 'getNotificationAppLaunchDetails') return {'notificationLaunchedApp': false};
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final service = SystemNotificationServiceImpl(
      fallback: InAppNotificationController(notices: notices),
      initializeSystemNotifications: () async => true,
    );
    final result = await service.show(remoteNotification('show-failure'));
    await finishMotion(tester);
    expect(result.displayed, isTrue);
    expect(result.fallbackUsed, isTrue);
    expect(find.text('Подписка скоро закончится'), findsOneWidget);
  });

  testWidgets('error tap retains full diagnostic dialog', (tester) async {
    final notices = await mountNotices(tester);
    InAppNotificationController(
      notices: notices,
    ).showErrorToast('Ошибка сети', diagnosticText: 'Full diagnostic detail');
    await finishMotion(tester);
    await tester.tap(find.text('Ошибка сети'));
    await finishMotion(tester);
    expect(find.byType(CustomAlertDialog), findsOneWidget);
    expect(find.text('Full diagnostic detail'), findsOneWidget);
    expect(notices.entries, isEmpty);
  });

  testWidgets('legacy CustomToast uses the same host as controller notifications', (tester) async {
    await mountNotices(tester, controller: appNoticeController);
    final context = tester.element(find.text('Фон приложения'));
    const CustomToast.success('Готово').show(context);
    InAppNotificationController().showInfoToast('Вносим изменения');
    await finishMotion(tester);
    expect(appNoticeController.entries, hasLength(2));
    expect(find.text('Вносим изменения'), findsOneWidget);
  });

  for (final mode in [AppThemeMode.light, AppThemeMode.dark, AppThemeMode.amoled]) {
    testWidgets('long fallback fits ${mode.name} at large text with keyboard and safe insets', (tester) async {
      final notices = await mountNotices(
        tester,
        mode: mode,
        textScale: 2,
        reduced: true,
        size: const Size(320, 640),
        insets: const EdgeInsets.only(bottom: 240),
        padding: const EdgeInsets.only(top: 24, bottom: 24),
      );
      InAppNotificationController(notices: notices).showRemoteNotificationFallback(
        title: 'Очень длинный заголовок уведомления о подписке',
        body: List.filled(30, 'Длинный текст уведомления.').join(' '),
        actionUrl: null,
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.byType(AppNoticeCard));
      expect(rect.left, greaterThanOrEqualTo(16));
      expect(rect.right, lessThanOrEqualTo(304));
      expect(rect.bottom, lessThanOrEqualTo(388));
      expect(rect.top, greaterThanOrEqualTo(24));
      expect(find.text('Открыть'), findsNothing);
    });
  }
}

NotificationEntity remoteNotification(String id) => NotificationEntity(
  id: id,
  category: NotificationCategory.system,
  priority: NotificationPriority.normal,
  title: 'Подписка скоро закончится',
  body: 'Осталось 3 дня. Продлите подписку, чтобы сохранить доступ ко всем серверам.',
  actionUrl: 'zeon://notifications/test',
  publishedAt: DateTime.utc(2026, 9, 16),
  expiresAt: null,
);
