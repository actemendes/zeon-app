import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/localization/translation_context.dart';
import 'package:zeon/core/localization/translation_loader.dart';
import 'package:zeon/features/notifications/model/notification_category.dart';
import 'package:zeon/features/notifications/service/system_notification_service.dart';
import 'package:zeon/features/profile/details/json_editor.dart';
import 'package:zeon/features/proxy/model/proxy_display_name.dart';
import 'package:zeon/features/proxy/widget/proxy_quality_indicator.dart';
import 'package:zeon/gen/translations.g.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

void main() {
  final catalogs = <AppLocale, Translations>{};
  setUpAll(() async {
    for (final locale in AppLocale.values) {
      catalogs[locale] = await loadTranslations(locale);
    }
  });
  const newPaths = [
    'common.open',
    'common.back',
    'common.copy',
    'common.copyError',
    'common.next',
    'common.previous',
    'intro.bindErrors',
    'pages.home.hideTip',
    'pages.home.internetEverywhere',
    'pages.home.youArePremium',
    'pages.home.premiumDaysRemaining',
    'pages.proxies.autoSelection',
    'pages.settings.general.notifications',
    'pages.profileDetails.editor',
    'dialogs.proxyInfo.quality',
    'errors.withDetails',
    'components.notifications',
  ];
  final base = _resource('en');
  for (final locale in AppLocale.values) {
    final tag = locale.languageTag;
    test('$tag has explicit interface translations and valid parameters', () {
      final data = _resource(tag);
      for (final path in newPaths) {
        _checkTranslation(_at(base, path), _at(data, path), '$tag:$path');
      }
    });

    test('$tag localizes Auto without modifying the concrete server name', () {
      final t = catalogs[locale]!;
      final outbound = OutboundInfo(
        tag: 'balance',
        tagDisplay: 'balance',
        type: 'balancer',
        groupSelectedTagDisplay: '🇩🇪 Germany | FAST',
      );
      final display = resolveOutboundDisplayInfo(outbound, translations: t);
      expect(display.title, '${t.pages.proxies.autoSelection} • Germany | FAST');
      expect(display.countryCode, 'DE');
      expect(outbound.groupSelectedTagDisplay, '🇩🇪 Germany | FAST');
      for (final category in NotificationCategory.values) {
        final channel = androidChannelForCategory(category, translations: t);
        expect(channel.name, isNotEmpty);
        expect(channel.description, isNotEmpty);
        expect(channel.id, startsWith('zeon_'));
      }
    });
  }

  test('premium countdown follows Russian and English plural rules', () {
    final ru = catalogs[AppLocale.ru]!.pages.home;
    expect(ru.premiumDaysRemaining(n: 1), 'Остался 1 день');
    expect(ru.premiumDaysRemaining(n: 2), 'Осталось 2 дня');
    expect(ru.premiumDaysRemaining(n: 5), 'Осталось 5 дней');
    expect(ru.premiumDaysRemaining(n: 11), 'Осталось 11 дней');
    expect(ru.premiumDaysRemaining(n: 21), 'Остался 21 день');
    final en = catalogs[AppLocale.en]!.pages.home;
    expect(en.premiumDaysRemaining(n: 1), '1 day remaining');
    expect(en.premiumDaysRemaining(n: 2), '2 days remaining');
    final ar = catalogs[AppLocale.ar]!.pages.home;
    expect(ar.premiumDaysRemaining(n: 2), 'تبقّى يومان');
    expect(ar.premiumDaysRemaining(n: 5), 'تبقّى 5 أيام');
  });

  testWidgets('presentation controls rebuild on locale changes including RTL and Chinese regions', (tester) async {
    for (final locale in AppLocale.values) {
      final t = locale.buildSync();
      await tester.pumpWidget(
        _app(
          locale,
          Builder(
            builder: (context) {
              return Column(children: [Text(context.translations.common.open), const QualityBars(healthScore: 90)]);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(t.common.open), findsOneWidget);
      expect(find.bySemanticsLabel(t.dialogs.proxyInfo.quality), findsOneWidget);
      final context = tester.element(find.byType(QualityBars));
      expect(
        Directionality.of(context),
        locale == AppLocale.ar || locale == AppLocale.fa ? TextDirection.rtl : TextDirection.ltr,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('config editor translates its controls and preserves JSON keys', (tester) async {
    for (final locale in [AppLocale.ru, AppLocale.en, AppLocale.ar, AppLocale.zhTw]) {
      final t = locale.buildSync();
      await tester.pumpWidget(_app(locale, JsonEditor(json: '{"server":"example.invalid"}', onChanged: (_) {})));
      await tester.pumpAndSettle();
      expect(find.text(t.pages.profileDetails.editor.title), findsOneWidget);
      expect(find.byTooltip(t.pages.profileDetails.editor.changeEditor), findsOneWidget);
      expect(find.byTooltip(t.common.copy), findsOneWidget);
      expect(find.text('server'), findsWidgets);
      expect(tester.takeException(), isNull);
    }
  });
}

Widget _app(AppLocale locale, Widget child) => MaterialApp(
  locale: Locale.fromSubtags(languageCode: locale.languageCode, countryCode: locale.countryCode),
  supportedLocales: AppLocaleUtils.supportedLocales,
  localizationsDelegates: const [InterfaceTranslationsDelegate(), ...GlobalMaterialLocalizations.delegates],
  home: Scaffold(body: child),
);

Map<String, dynamic> _resource(String tag) =>
    jsonDecode(File('assets/translations/$tag.i18n.json').readAsStringSync()) as Map<String, dynamic>;

Object? _at(Map<String, dynamic> data, String path) {
  Object? value = data;
  for (final key in path.split('.')) {
    expect(value, isA<Map<String, dynamic>>(), reason: path);
    value = (value! as Map<String, dynamic>)[key];
  }
  return value;
}

void _checkTranslation(Object? base, Object? translated, String path) {
  if (base is Map<String, dynamic>) {
    expect(translated, isA<Map<String, dynamic>>(), reason: path);
    final target = translated! as Map<String, dynamic>;
    if (base.containsKey('other')) {
      expect(target['other'], isNotEmpty, reason: path);
      for (final value in target.values) {
        expect(value, isA<String>(), reason: path);
        expect(value, isNotEmpty, reason: path);
      }
    } else {
      for (final entry in base.entries) {
        _checkTranslation(entry.value, target[entry.key], '$path.${entry.key}');
      }
    }
    return;
  }
  expect(translated, isA<String>(), reason: path);
  expect(translated, isNotEmpty, reason: path);
  final parameters = RegExp(r'\$\{?(\w+)\}?');
  Set<String> params(String value) => parameters.allMatches(value).map((m) => m.group(1)!).toSet();
  expect(params(translated! as String), params(base! as String), reason: path);
}
