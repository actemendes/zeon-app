import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translation_context.dart';
import 'package:zeon/core/localization/translation_loader.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/features/proxy/model/proxy_display_name.dart';
import 'package:zeon/features/proxy/model/server_country_names.dart';
import 'package:zeon/features/proxy/model/server_name_localization.dart';
import 'package:zeon/features/proxy/widget/proxy_tile.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

void main() {
  final catalogs = <AppLocale, Translations>{};
  setUpAll(() async {
    for (final locale in AppLocale.values) {
      catalogs[locale] = await loadTranslations(locale);
    }
  });

  for (final locale in AppLocale.values) {
    test('${locale.languageTag}: explicit country resources cover every recognized name', () {
      final json =
          jsonDecode(File('assets/translations/${locale.languageTag}.i18n.json').readAsStringSync())
              as Map<String, dynamic>;
      final names =
          ((json['pages'] as Map<String, dynamic>)['proxies'] as Map<String, dynamic>)['serverNames']
              as Map<String, dynamic>;
      final countries = names['countries(map)'] as Map<String, dynamic>;
      expect(countries.keys, containsAll(russianServerCountryCodes.values.toSet()));
      expect(names['fast'], locale == AppLocale.ru ? 'БЫСТРЫЙ' : 'FAST');
      expect(names['bypass'], locale == AppLocale.ru ? 'СВЯЗЬ' : 'BYPASS');
      final t = catalogs[locale]!;
      for (final alias in russianServerCountryCodes.entries) {
        final raw = '${alias.key}12 | БЫСТРЫЙ⚡';
        final country = alias.value == 'ZZ' ? t.common.unknown : countries[alias.value];
        expect(
          localizeServerDisplayName(raw, t),
          locale == AppLocale.ru ? raw : '${country}12 | FAST⚡',
          reason: '${locale.languageTag}: ${alias.key}',
        );
      }
    });
  }

  test('preserves flags, numbering, separators and both service emojis', () {
    final en = catalogs[AppLocale.en]!;
    expect(localizeServerDisplayName('🇩🇪Германия2 | БЫСТРЫЙ⚡', en), '🇩🇪Germany2 | FAST⚡');
    expect(localizeServerDisplayName(' 🇺🇸 США #12 | СВЯЗЬ📱 ', en), ' 🇺🇸 United States #12 | BYPASS📱 ');
    expect(localizeServerDisplayName('ОАЭ | СВЯЗЬ📱', en), 'United Arab Emirates | BYPASS📱');
    expect(localizeServerDisplayName('Германия | БЫСТРЫЙ⚡ | СВЯЗЬ📱', en), 'Germany | FAST⚡ | BYPASS📱');
    expect(localizeServerDisplayName('🏳️Неизвестно | БЫСТРЫЙ⚡', en), '🏳️Unknown | FAST⚡');
  });

  test('uses selected language for countries and preserves Russian verbatim', () {
    const raw = '🇩🇪Германия2 | СВЯЗЬ📱';
    expect(localizeServerDisplayName(raw, catalogs[AppLocale.fr]!), '🇩🇪Allemagne2 | BYPASS📱');
    expect(localizeServerDisplayName(raw, catalogs[AppLocale.tr]!), '🇩🇪Almanya2 | BYPASS📱');
    expect(localizeServerDisplayName(raw, catalogs[AppLocale.zhCn]!), '🇩🇪德国2 | BYPASS📱');
    expect(localizeServerDisplayName(raw, catalogs[AppLocale.zhTw]!), '🇩🇪德國2 | BYPASS📱');
    expect(localizeServerDisplayName(raw, catalogs[AppLocale.ru]!), raw);
  });

  test('does not guess country from flags or rewrite custom names/operators', () {
    final en = catalogs[AppLocale.en]!;
    for (final raw in [
      '🇩🇪Personal server',
      'Моя Германия | БЫСТРЫЙ+',
      'ГерманияVPN | СВЯЗЬPLUS',
      'Germany | FAST⚡',
      'БЫСТРЫЙ сервер',
      'Моя связь',
    ]) {
      expect(localizeServerDisplayName(raw, en), raw);
    }
    expect(localizeServerDisplayName('Германия2 | МТС, БИЛАЙН', en), 'Germany2 | МТС, БИЛАЙН');
    expect(localizeServerDisplayName('Мой сервер | БЫСТРЫЙ⚡', en), 'Мой сервер | FAST⚡');
  });

  test('Auto and manual display share localization without changing selection identity', () {
    final en = catalogs[AppLocale.en]!;
    final leaf = OutboundInfo(tag: 'opaque-node-id', tagDisplay: '🇩🇪Германия2 | СВЯЗЬ📱', type: 'vless');
    final auto = OutboundInfo(tag: 'balance', tagDisplay: 'balance', type: 'balancer', groupSelectedTag: leaf.tag);
    final leafBytes = leaf.writeToBuffer();
    final autoBytes = auto.writeToBuffer();
    final display = resolveOutboundDisplayInfo(auto, translations: en, allOutbounds: [leaf]);
    expect(display.title, 'Auto selection • Germany2 | BYPASS📱');
    expect(display.countryCode, 'DE');
    expect(formatOutboundTitle(leaf, translations: en), 'Germany2 | BYPASS📱');
    expect(resolveRealOutboundTag(autoOutbound: auto, allOutbounds: [leaf]), 'opaque-node-id');
    expect(findOutboundByTagOrDisplay([leaf], '🇩🇪Германия2 | СВЯЗЬ📱'), same(leaf));
    expect(findOutboundByTagOrDisplay([leaf], 'Germany2 | BYPASS📱'), isNull);
    expect(leaf.writeToBuffer(), orderedEquals(leafBytes));
    expect(auto.writeToBuffer(), orderedEquals(autoBytes));
  });

  test('localizes Auto fallback embedded in the server-provided display name', () {
    final auto = OutboundInfo(tag: 'balance', tagDisplay: 'balance → 🇫🇷Франция3 | БЫСТРЫЙ⚡', type: 'balancer');
    final display = resolveOutboundDisplayInfo(auto, translations: catalogs[AppLocale.es]!);
    expect(display.title, 'Selección automática • Francia3 | FAST⚡');
    expect(display.countryCode, 'FR');
  });

  testWidgets('server tile changes language while taps keep the original outbound tag', (tester) async {
    final leaf = OutboundInfo(tag: 'node-id', tagDisplay: '🇩🇪Германия2 | БЫСТРЫЙ⚡', type: 'vless');
    String? selected;
    for (final locale in [AppLocale.ru, AppLocale.en, AppLocale.fr, AppLocale.ar, AppLocale.zhTw]) {
      final t = catalogs[locale]!;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [translationsProvider.overrideWith((ref) => t)],
          child: MaterialApp(
            locale: locale.flutterLocale,
            supportedLocales: AppLocaleUtils.supportedLocales,
            localizationsDelegates: const [InterfaceTranslationsDelegate(), ...GlobalMaterialLocalizations.delegates],
            home: Scaffold(
              body: SizedBox(
                width: 400,
                child: ProxyTile(
                  leaf,
                  selected: false,
                  isActive: false,
                  countryCode: 'DE',
                  ipv6Mode: IPv6Mode.disable,
                  onTap: () => selected = leaf.tag,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final label = locale == AppLocale.ru
          ? 'Германия2 | БЫСТРЫЙ⚡'
          : '${t.pages.proxies.serverNames.countries['DE']}2 | FAST⚡';
      expect(find.text(label), findsOneWidget);
      await tester.tap(find.text(label));
      expect(selected, 'node-id');
      expect(leaf.tagDisplay, '🇩🇪Германия2 | БЫСТРЫЙ⚡');
      expect(tester.takeException(), isNull);
    }
  });
}
