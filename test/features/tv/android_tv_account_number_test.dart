import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/device/android_tv_provider.dart';
import 'package:zeon/core/http_client/dio_http_client.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/notification/app_notice.dart';
import 'package:zeon/core/notification/in_app_notification_controller.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/core/router/dialog/widgets/zeon_dialog.dart';
import 'package:zeon/core/theme/app_theme.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/core/widget/keyboard_focus_outline.dart';
import 'package:zeon/core/widget/tv_display_layout.dart';
import 'package:zeon/features/intro/widget/intro_page.dart';
import 'package:zeon/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:zeon/features/mobile/data/mobile_device_rebind_service.dart';
import 'package:zeon/features/profile/data/profile_data_source.dart';
import 'package:zeon/features/profile/data/profile_repository.dart';
import 'package:zeon/gen/translations_ru.g.dart';

Finder _key(String name) => find.byKey(ValueKey(name));
Finder get _submit => _key(UiNames.buttonIntroBindSubmit);
Finder get _display => _key('tv-account-number-display');

String _number(WidgetTester tester) =>
    tester.widget<Text>(find.descendant(of: _display, matching: find.byType(Text))).data!;
bool _submitEnabled(WidgetTester tester) => tester.widget<ButtonStyleButton>(_submit).onPressed != null;

void _expectKeypadActionColumn(WidgetTester tester, {bool besideInput = false}) {
  final firstDigit = tester.getRect(_key('tv-account-digit-1'));
  final lastDigit = tester.getRect(_key('tv-account-digit-3'));
  final keypadBottom = tester.getRect(_key('tv-account-backspace')).bottom;
  final primary = tester.getRect(_submit);
  final secondary = tester.getRect(_key('tv-account-use-link'));
  for (final action in [primary, secondary]) {
    expect(action.left, closeTo(firstDigit.left, 1));
    expect(action.right, closeTo(lastDigit.right, 1));
    expect(action.top, greaterThan(keypadBottom), reason: 'Actions belong below the keypad in the same column.');
    if (besideInput) {
      expect(
        action.left,
        greaterThan(tester.getRect(_display).right),
        reason: 'On TV the entry field is left of the keypad and actions.',
      );
    }
  }
  expect(secondary.top, greaterThan(primary.bottom));
}

bool _hasPrimaryFocus(Finder target) {
  final element = target.evaluate().single;
  var inside = false;
  FocusManager.instance.primaryFocus?.context?.visitAncestorElements((ancestor) {
    if (ancestor == element) inside = true;
    return !inside;
  });
  return inside;
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

Future<void> _typeNumber(WidgetTester tester, String number) async {
  const keys = [
    LogicalKeyboardKey.digit0,
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];
  for (final digit in number.split('')) {
    await _press(tester, keys[int.parse(digit)]);
  }
}

void main() {
  setUpAll(() async {
    for (final entry in jsonDecode(await rootBundle.loadString('FontManifest.json')) as List) {
      final font = entry as Map<String, dynamic>;
      final loader = FontLoader(font['family'] as String);
      for (final asset in font['fonts'] as List) {
        loader.addFont(rootBundle.load((asset as Map<String, dynamic>)['asset'] as String));
      }
      await loader.load();
    }
  });

  testWidgets('TV starts on digit 1 with visible focus and no editable field or IME', (tester) async {
    final fixture = await _pumpDialog(tester);
    expect(_hasPrimaryFocus(_key('tv-account-digit-1')), isTrue);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(EditableText), findsNothing);
    expect(tester.testTextInput.hasAnyClients, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(_submitEnabled(tester), isFalse);
    expect(
      find.descendant(
        of: _key('tv-account-digit-1'),
        matching: find.byWidgetPredicate(
          (widget) => widget is CustomPaint && widget.foregroundPainter is KeyboardFocusOutlinePainter,
        ),
      ),
      findsOneWidget,
    );
    expect(fixture.imports.rawInputs, isEmpty);
  });

  testWidgets('D-pad moves in four directions without entering or submitting digits', (tester) async {
    final fixture = await _pumpDialog(tester);
    for (final step in [
      (LogicalKeyboardKey.arrowRight, '2'),
      (LogicalKeyboardKey.arrowDown, '5'),
      (LogicalKeyboardKey.arrowLeft, '4'),
      (LogicalKeyboardKey.arrowUp, '1'),
    ]) {
      await _press(tester, step.$1);
      expect(_hasPrimaryFocus(_key('tv-account-digit-${step.$2}')), isTrue);
      expect(_number(tester), '…');
      expect(fixture.imports.rawInputs, isEmpty);
    }
    await _press(tester, LogicalKeyboardKey.select);
    expect(_number(tester), '1');
    expect(_submitEnabled(tester), isTrue);
    expect(fixture.imports.rawInputs, isEmpty, reason: 'A valid number must never submit automatically.');
  });

  testWidgets('held digit, backspace and Select edit only once per physical press', (tester) async {
    final fixture = await _pumpDialog(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.digit7);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.digit7);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.digit7);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.digit7);
    await tester.pumpAndSettle();
    expect(_number(tester), '7');
    await _press(tester, LogicalKeyboardKey.numpad8);
    expect(_number(tester), '78');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(_number(tester), '7');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(_number(tester), '71');
    expect(fixture.imports.rawInputs, isEmpty);
  });

  testWidgets('remote reaches clear, zero and backspace without accidental edits', (tester) async {
    await _pumpDialog(tester);
    await _typeNumber(tester, '123');
    for (var i = 0; i < 3; i++) {
      await _press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(_hasPrimaryFocus(_key('tv-account-clear')), isTrue);
    expect(_number(tester), '123');
    await _press(tester, LogicalKeyboardKey.select);
    expect(_number(tester), '…');
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_hasPrimaryFocus(_key('tv-account-digit-0')), isTrue);
    await _press(tester, LogicalKeyboardKey.select);
    expect(_number(tester), '0');
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_hasPrimaryFocus(_key('tv-account-backspace')), isTrue);
    expect(_number(tester), '0');
    await _press(tester, LogicalKeyboardKey.select);
    expect(_number(tester), '…');
    await _press(tester, LogicalKeyboardKey.select);
    expect(_number(tester), '…', reason: 'Deleting an empty number is safe.');
  });

  testWidgets('invalid zero, leading zero and unsafe integer stay visible but cannot submit', (tester) async {
    final fixture = await _pumpDialog(tester);
    for (final input in ['0', '0123', '9007199254740992', '10000000000000000']) {
      await tester.tap(_key('tv-account-clear'));
      await tester.pumpAndSettle();
      await _typeNumber(tester, input);
      expect(_number(tester), input, reason: 'Never silently alter an account identity.');
      expect(_submitEnabled(tester), isFalse);
      expect(_key('tv-account-number-error'), findsOneWidget);
      expect(fixture.imports.rawInputs, isEmpty);
    }
    await tester.tap(_key('tv-account-clear'));
    await tester.pumpAndSettle();
    expect(_key('tv-account-number-error'), findsNothing);
  });

  for (final input in ['12', '9007199254740991']) {
    testWidgets('explicit submit preserves $input through real normalizer and fake rebind', (tester) async {
      final fixture = await _pumpDialog(tester);
      await _typeNumber(tester, input);
      expect(fixture.imports.rawInputs, isEmpty);
      for (var i = 0; i < 3; i++) {
        await _press(tester, LogicalKeyboardKey.arrowDown);
      }
      await _press(tester, LogicalKeyboardKey.arrowRight);
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_hasPrimaryFocus(_submit), isTrue);
      expect(fixture.imports.rawInputs, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(fixture.imports.rawInputs, [input]);
      expect(fixture.imports.modes, [MobileConnLinkImportMode.fast]);
      expect(fixture.imports.normalized.single.openId, input);
      expect(
        fixture.imports.normalized.single.primaryConnLink,
        Uri.parse(MobileConnLinkImportService.apiBaseUrl).resolve('/open/$input').toString(),
      );
      expect(fixture.rebind.results, isEmpty);
      expect(fixture.container.read(Preferences.introCompleted), isFalse);
      fixture.imports.completeSuccess();
      await tester.pumpAndSettle();
      expect(fixture.rebind.results.single.openId, input);
      expect(fixture.container.read(Preferences.introCompleted), isTrue);
      expect(_key('test-home'), findsOneWidget);
      expect(fixture.notices.successes, hasLength(1));
      expect(fixture.notices.errors, isEmpty);
    });
  }

  testWidgets('pending import blocks edits and duplicate submission; failure keeps number for retry', (tester) async {
    final fixture = await _pumpDialog(tester);
    await _typeNumber(tester, '123456');
    await tester.tap(_submit);
    await tester.pump();
    expect(_submitEnabled(tester), isFalse);
    expect(tester.widget<TextButton>(_key('tv-account-use-link')).onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(_number(tester), '123456');
    expect(fixture.imports.rawInputs, ['123456']);
    fixture.imports.pending.completeError(const MobileConnLinkImportException('bind_link_not_found'));
    await tester.pumpAndSettle();
    expect(_number(tester), '123456');
    expect(_submitEnabled(tester), isTrue);
    expect(fixture.notices.errors, hasLength(1));
    expect(fixture.container.read(Preferences.introCompleted), isFalse);
    expect(fixture.rebind.results, isEmpty);
    fixture.imports.pending = Completer<MobileConnLinkImportResult>();
    await tester.tap(_submit);
    await tester.pump();
    fixture.imports.completeSuccess();
    await tester.pumpAndSettle();
    expect(fixture.imports.rawInputs, ['123456', '123456']);
    expect(_key('test-home'), findsOneWidget);
  });

  testWidgets('TV link fallback opens the original URL field and preserves its import path', (tester) async {
    final fixture = await _pumpDialog(tester);
    await _typeNumber(tester, '123');
    await tester.tap(_key('tv-account-use-link'));
    await tester.pumpAndSettle();
    expect(_display, findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.widget<TextField>(_key(UiNames.inputIntroBindLink)).controller!.text, isEmpty);
    const url = 'https://example.invalid/subscription?token=fixture';
    await tester.enterText(_key(UiNames.inputIntroBindLink), url);
    await tester.pumpAndSettle();
    expect(_submitEnabled(tester), isTrue);
    await tester.tap(_submit);
    await tester.pump();
    expect(fixture.imports.rawInputs, [url]);
    expect(fixture.imports.normalized.single.primaryConnLink, url);
    fixture.imports.completeSuccess();
    await tester.pumpAndSettle();
    expect(_key('test-home'), findsOneWidget);
  });

  testWidgets('pending import blocks Back, barrier and close until success reaches Home', (tester) async {
    final fixture = await _pumpDialog(tester);
    await _typeNumber(tester, '123456');
    await tester.tap(_submit);
    await tester.pump();
    expect(fixture.imports.rawInputs, ['123456']);
    final close = find.descendant(of: _key('tv-account-number-dialog'), matching: find.byType(IconButton));
    expect(tester.widget<IconButton>(close).onPressed, isNull);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(_key('tv-account-number-dialog'), findsOneWidget);
    await tester.tapAt(const Offset(4, 4));
    await tester.pump();
    expect(_key('tv-account-number-dialog'), findsOneWidget);
    await tester.tap(close);
    await tester.pump();
    expect(_key('tv-account-number-dialog'), findsOneWidget);
    expect(fixture.imports.rawInputs, ['123456']);
    fixture.imports.completeSuccess();
    await tester.pumpAndSettle();
    expect(fixture.rebind.results.single.openId, '123456');
    expect(fixture.notices.errors, isEmpty);
    expect(fixture.notices.successes, hasLength(1));
    expect(fixture.container.read(Preferences.introCompleted), isTrue);
    expect(_key('test-home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed import restores cancellation without changing account or intro state', (tester) async {
    final fixture = await _pumpDialog(tester);
    await _typeNumber(tester, '123456');
    await tester.tap(_submit);
    await tester.pump();
    fixture.imports.pending.completeError(const MobileConnLinkImportException('bind_link_not_found'));
    await tester.pumpAndSettle();
    final close = find.descendant(of: _key('tv-account-number-dialog'), matching: find.byType(IconButton));
    expect(tester.widget<IconButton>(close).onPressed, isNotNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_key('tv-account-number-dialog'), findsNothing);
    expect(fixture.rebind.results, isEmpty);
    expect(fixture.container.read(Preferences.introCompleted), isFalse);
    expect(_key('test-home'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile retains the URL keyboard and alphanumeric account code path', (tester) async {
    final fixture = await _pumpDialog(tester, television: false, size: const Size(393, 852));
    expect(_key('tv-account-number-dialog'), findsNothing);
    final field = tester.widget<TextField>(_key(UiNames.inputIntroBindLink));
    expect(field.keyboardType, TextInputType.url);
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.enterText(_key(UiNames.inputIntroBindLink), 'AB_cd-123');
    await tester.pumpAndSettle();
    expect(_submitEnabled(tester), isTrue);
    await tester.tap(_submit);
    await tester.pump();
    expect(fixture.imports.rawInputs, ['AB_cd-123']);
    expect(fixture.imports.normalized.single.openId, 'AB_cd-123');
    fixture.imports.completeSuccess();
    await tester.pumpAndSettle();
    expect(_key('test-home'), findsOneWidget);
  });

  testWidgets('Back cancels TV account entry without account or preference changes', (tester) async {
    final fixture = await _pumpDialog(tester);
    await _typeNumber(tester, '123');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_key('tv-account-number-dialog'), findsNothing);
    expect(fixture.imports.rawInputs, isEmpty);
    expect(fixture.rebind.results, isEmpty);
    expect(fixture.container.read(Preferences.introCompleted), isFalse);
  });

  for (final mode in [AppThemeMode.light, AppThemeMode.dark, AppThemeMode.amoled]) {
    testWidgets('actual production TV dialog renders with focus in ${mode.name}', (tester) async {
      await _pumpDialog(tester, mode: mode);
      await _typeNumber(tester, '12345678');
      expect(_hasPrimaryFocus(_key('tv-account-digit-1')), isTrue);
      expect(_submit.hitTestable(), findsOneWidget);
      expect(_key('tv-account-digit-0').hitTestable(), findsOneWidget);
      _expectKeypadActionColumn(tester, besideInput: true);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'numeric-account-${mode.name}');
    });
  }

  testWidgets('compact TV dialog keeps keypad and actions reachable without overflow', (tester) async {
    await _pumpDialog(tester, size: const Size(480, 540));
    await _typeNumber(tester, '9007199254740991');
    await tester.ensureVisible(_key('tv-account-digit-0'));
    await tester.pumpAndSettle();
    expect(_key('tv-account-digit-0').hitTestable(), findsOneWidget);
    expect(_submit.hitTestable(), findsOneWidget);
    _expectKeypadActionColumn(tester);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'numeric-account-compact');
  });

  testWidgets('RTL shell keeps number and keypad left-to-right with physical arrow navigation', (tester) async {
    await _pumpDialog(tester, rtl: true);
    await _typeNumber(tester, '12345678');
    expect(Directionality.of(tester.element(_key('tv-account-digit-1'))), TextDirection.ltr);
    expect(tester.getCenter(_key('tv-account-digit-1')).dx, lessThan(tester.getCenter(_key('tv-account-digit-3')).dx));
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_hasPrimaryFocus(_key('tv-account-digit-2')), isTrue);
    expect(_number(tester), '12345678');
    expect(_submit.hitTestable(), findsOneWidget);
    _expectKeypadActionColumn(tester);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'numeric-account-rtl');
  });

  testWidgets('large-text landscape TV keeps focused digits and submit reachable with D-pad', (tester) async {
    final fixture = await _pumpDialog(tester, size: const Size(720, 405), textScale: 2);
    expect(MediaQuery.textScalerOf(tester.element(_display)).scale(1), 2);
    expect(_hasPrimaryFocus(_key('tv-account-digit-1')), isTrue);
    expect(_key('tv-account-digit-1').hitTestable(), findsOneWidget);
    await _typeNumber(tester, '12');
    for (var i = 0; i < 3; i++) {
      await _press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(_hasPrimaryFocus(_key('tv-account-clear')), isTrue);
    expect(_key('tv-account-clear').hitTestable(), findsOneWidget);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_hasPrimaryFocus(_submit), isTrue);
    expect(_submit.hitTestable(), findsOneWidget);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_hasPrimaryFocus(_key('tv-account-use-link')), isTrue);
    expect(_key('tv-account-use-link').hitTestable(), findsOneWidget);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_hasPrimaryFocus(_submit), isTrue);
    _expectKeypadActionColumn(tester, besideInput: true);
    expect(fixture.imports.rawInputs, isEmpty);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'numeric-account-landscape-large-text');
  });
}

class _Fixture {
  _Fixture(this.container, this.imports, this.rebind, this.notices);
  final ProviderContainer container;
  final _RecordingImport imports;
  final _RecordingRebind rebind;
  final _RecordingNotices notices;
}

Future<_Fixture> _pumpDialog(
  WidgetTester tester, {
  bool television = true,
  AppThemeMode mode = AppThemeMode.dark,
  Size size = const Size(960, 540),
  bool rtl = false,
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final imports = _RecordingImport(preferences);
  final rebind = _RecordingRebind();
  final notices = _RecordingNotices();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWith((ref) => preferences),
      translationsProvider.overrideWith((ref) => TranslationsRu()),
      androidTvProvider.overrideWith((ref) => television),
      mobileConnLinkImportServiceProvider.overrideWithValue(imports),
      mobileDeviceRebindServiceProvider.overrideWithValue(rebind),
      inAppNotificationControllerProvider.overrideWithValue(notices),
    ],
  );
  await container.read(sharedPreferencesProvider.future);
  await container.read(translationsProvider.future);
  await container.read(androidTvProvider.future);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open-account'),
              onPressed: () => showZeonDialog<void>(context, const IntroAccountDialog()),
              child: const Text('ZEON'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/home',
        name: 'home',
        builder: (_, _) => const Scaffold(key: ValueKey('test-home')),
      ),
    ],
  );
  addTearDown(() {
    router.dispose();
    container.dispose();
  });
  final theme = AppTheme(mode, 'Montserrat');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: true, textScaler: TextScaler.linear(textScale)),
        child: RepaintBoundary(
          key: const ValueKey('numeric-capture'),
          child: TvDisplayLayout(
            isTelevision: television,
            child: MaterialApp.router(
              debugShowCheckedModeBanner: false,
              routerConfig: router,
              theme: mode == AppThemeMode.light ? theme.lightTheme(null) : theme.darkTheme(null),
              locale: rtl ? const Locale('ar') : const Locale('ru'),
              supportedLocales: const [Locale('ru'), Locale('ar')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(_key('open-account'));
  await tester.pumpAndSettle();
  return _Fixture(container, imports, rebind, notices);
}

Future<void> _capture(WidgetTester tester, String name) async {
  const directory = String.fromEnvironment('TV_ACCOUNT_EVIDENCE_DIR');
  if (directory.isEmpty) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(_key('numeric-capture'));
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

// Any accidental use of a transport or profile dependency fails the test.
class _UnusedHttpClient extends Fake implements DioHttpClient {}

class _UnusedProfileRepository extends Fake implements ProfileRepository {}

class _UnusedProfileDataSource extends Fake implements ProfileDataSource {}

class _RecordingImport extends MobileConnLinkImportService {
  _RecordingImport(SharedPreferences preferences)
    : super(
        httpClient: _UnusedHttpClient(),
        profileRepository: _UnusedProfileRepository(),
        profileDataSource: _UnusedProfileDataSource(),
        preferences: preferences,
      );
  final rawInputs = <String>[];
  final modes = <MobileConnLinkImportMode>[];
  final normalized = <MobileConnLinkInput>[];
  Completer<MobileConnLinkImportResult> pending = Completer<MobileConnLinkImportResult>();

  @override
  Future<MobileConnLinkImportResult> importConnectionLink(
    String rawInput, {
    int? userId,
    String? apiStatus,
    DateTime? apiExpiresAt,
    String? apiLogin,
    bool clearUserIdWhenMissing = true,
    MobileConnLinkImportMode mode = MobileConnLinkImportMode.standard,
  }) {
    rawInputs.add(rawInput);
    modes.add(mode);
    normalized.add(normalizeConnectionLink(rawInput));
    return pending.future;
  }

  void completeSuccess() {
    final input = normalized.last;
    pending.complete(
      MobileConnLinkImportResult(
        connLink: input.primaryConnLink,
        importedUrl: input.primaryConnLink,
        openId: input.openId,
        userId: null,
      ),
    );
  }
}

class _RecordingRebind extends Fake implements MobileDeviceRebindService {
  final results = <MobileConnLinkImportResult>[];
  @override
  Future<bool> syncManualImportRebind(
    MobileConnLinkImportResult importResult, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    results.add(importResult);
    return true;
  }
}

class _RecordingNotices extends InAppNotificationController {
  final errors = <String>[];
  final successes = <String>[];
  @override
  AppNoticeHandle? showErrorToast(String message, {String? diagnosticText}) {
    errors.add(message);
    return null;
  }

  @override
  AppNoticeHandle? showSuccessToast(String message) {
    successes.add(message);
    return null;
  }
}
