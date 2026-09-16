import 'dart:convert';
import 'dart:io';

import 'package:circle_flags/circle_flags.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/features/home/widget/home_page.dart';
import 'package:zeon/features/profile/overview/profile_menu_page.dart';
import 'package:zeon/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:zeon/features/proxy/overview/proxies_overview_page.dart';
import 'package:zeon/features/proxy/widget/proxy_tile.dart';
import 'package:zeon/gen/translations_ru.g.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

import 'approved_interface_test.dart' as ui;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // Precompile the real packaged flags before the fake widget clock starts.
    for (final country in ['NL', 'DE', 'FI', 'FR', 'US', 'JP']) {
      final source = File(
        'build/unit_test_assets/packages/circle_flags/assets/svg/${country.toLowerCase()}.svg',
      ).readAsStringSync();
      final bytes = await SvgStringLoader(source).loadBytes(null);
      await svg.cache.putIfAbsent(CircleFlag(country).loader.cacheKey(null), () => Future.value(bytes));
    }
    for (final entry in jsonDecode(await rootBundle.loadString('FontManifest.json')) as List) {
      final font = entry as Map<String, dynamic>;
      final loader = FontLoader(font['family'] as String);
      for (final asset in font['fonts'] as List) {
        loader.addFont(rootBundle.load((asset as Map<String, dynamic>)['asset'] as String));
      }
      await loader.load();
    }
  });
  for (final light in [false, true]) {
    for (final (device, size, scale) in [
      ('phone', const Size(393, 852), 1.0),
      ('tablet', const Size(768, 1024), 1.0),
      ('desktop', const Size(1200, 850), 1.0),
      ('narrow', const Size(320, 740), 1.5),
    ]) {
      testWidgets('servers $device light=$light', (tester) async {
        final container = await ui.pumpPage(
          tester,
          const ProxiesOverviewPage(),
          size: size,
          scale: scale,
          light: light,
          proxies: PreviewProxies.new,
        );
        await tester.runAsync(() => vg.waitForPendingDecodes());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(ProxyTile), findsWidgets);
        await ui.capture(tester, '$device-servers-${light ? 'light' : 'dark'}');
        final tile = find.byWidgetPredicate((w) => w is ProxyTile && w.proxy.tag == 'de');
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await tester.pump();
        expect(container.read(proxiesOverviewNotifierProvider).requireValue?.selected, 'de');
        expect(tester.widget<ProxyTile>(tile).selected, isTrue);
        // The existing flag now participates in selecting the entire card.
        final flag = find.descendant(of: tile, matching: find.byKey(const ValueKey('proxy-ipv6-flag-frame')));
        await tester.tapAt(tester.getCenter(flag));
        await tester.pump();
        final notifier = container.read(proxiesOverviewNotifierProvider.notifier) as PreviewProxies;
        expect(notifier.selections, ['select/de', 'select/de']);
        await tester.tap(find.byKey(const ValueKey('proxies_test_delay')));
        await tester.pump();
        expect(notifier.testedGroup, 'select');
        final t = TranslationsRu();
        await tester.tap(find.byTooltip(t.pages.proxies.sort));
        await tester.pumpAndSettle();
        await tester.tap(find.text(ProxiesSort.name.present(t)).last);
        await tester.pumpAndSettle();
        expect(container.read(proxiesSortNotifierProvider), ProxiesSort.name);
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final light in [false, true]) {
    for (final (name, page) in <(String, Widget)>[('home', const HomePage()), ('profile', const ProfileMenuPage())]) {
      testWidgets('$name updated typography light=$light', (tester) async {
        await ui.pumpPage(tester, page, light: light);
        expect(tester.takeException(), isNull);
        await ui.capture(tester, 'phone-$name-${light ? 'light' : 'dark'}');
      });
    }
  }
}

// Synthetic preview values; no account data or native VPN is used.
class PreviewProxies extends ProxiesOverviewNotifier {
  final selections = <String>[];
  String? testedGroup;
  @override
  Stream<OutboundGroup?> build() => Stream.value(
    OutboundGroup(
      tag: 'select',
      selected: 'auto',
      items: [
        OutboundInfo(
          tag: 'auto',
          tagDisplay: 'Автовыбор',
          type: 'balancer',
          isGroup: true,
          groupSelectedTag: 'nl',
          groupSelectedTagDisplay: 'Нидерланды',
          urlTestDelay: 42,
          healthScore: 95,
          success: true,
        ),
        for (final (tag, title, ping, score) in [
          ('nl', '🇳🇱 Нидерланды', 42, 95),
          ('de', '🇩🇪 Германия', 58, 89),
          ('fi', '🇫🇮 Финляндия', 73, 78),
          ('fr', '🇫🇷 Франция', 92, 70),
          ('us', '🇺🇸 США', 145, 60),
          ('jp', '🇯🇵 Япония', 65000, 0),
        ])
          OutboundInfo(
            tag: tag,
            tagDisplay: title,
            type: 'proxy',
            urlTestDelay: ping,
            healthScore: score,
            success: score > 0,
            ipv6Status: 'not_tested',
          ),
      ],
    ),
  );
  @override
  Future<void> changeProxy(String groupTag, String outboundTag) async {
    selections.add('$groupTag/$outboundTag');
    final next = OutboundGroup()..mergeFromMessage(state.requireValue!);
    next.selected = outboundTag;
    state = AsyncData(next);
  }

  @override
  Future<void> urlTest(String groupTag) async => testedGroup = groupTag;
}
