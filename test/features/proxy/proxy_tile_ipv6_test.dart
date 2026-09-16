import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/features/proxy/widget/proxy_tile.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

void main() {
  Future<void> pumpTile(WidgetTester tester, {required IPv6Mode mode, required String status}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [translationsProvider.overrideWith((ref) => TranslationsEn())],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: ProxyTile(
                OutboundInfo(tag: 'node', tagDisplay: 'Node', ipv6Status: status, urlTestDelay: 123),
                selected: false,
                isActive: false,
                countryCode: 'US',
                ipv6Status: status,
                ipv6StatusText: 'IPv6 $status',
                ipv6Mode: mode,
                onTap: null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  BoxDecoration? flagDecoration(WidgetTester tester) {
    final frame = tester.widget<Container>(find.byKey(const ValueKey('proxy-ipv6-flag-frame')));
    return frame.decoration as BoxDecoration?;
  }

  for (final mode in IPv6Mode.values) {
    testWidgets('${mode.key}: supported retains the green status frame only when IPv6 is enabled', (tester) async {
      await pumpTile(tester, mode: mode, status: 'supported');

      final border = flagDecoration(tester)?.border as Border?;
      if (mode == IPv6Mode.disable) {
        expect(border, isNull);
      } else {
        expect(border?.top.width, 2);
        expect(border?.top.color, const Color(0xFF3CE74F));
      }
      expect(find.byKey(const ValueKey('proxy-ping')), findsOneWidget);
      expect(find.byKey(const ValueKey('proxy-ipv6-unavailable-cross')), findsNothing);
    });

    testWidgets('${mode.key}: not tested has no outline and keeps ping', (tester) async {
      await pumpTile(tester, mode: mode, status: 'not_tested');

      expect(flagDecoration(tester)?.border, isNull);
      expect(find.byKey(const ValueKey('proxy-ping')), findsOneWidget);
      expect(find.byKey(const ValueKey('proxy-ipv6-unavailable-cross')), findsNothing);
    });
  }

  testWidgets('ipv6_only: unavailable has no outline and replaces ping with a cross', (tester) async {
    await pumpTile(tester, mode: IPv6Mode.only, status: 'unavailable');

    expect(flagDecoration(tester)?.border, isNull);
    expect(find.byKey(const ValueKey('proxy-ping')), findsNothing);
    expect(find.byKey(const ValueKey('proxy-ipv6-unavailable-cross')), findsOneWidget);
  });

  for (final mode in [IPv6Mode.enable, IPv6Mode.prefer]) {
    testWidgets('${mode.key}: unavailable has no outline and keeps ping', (tester) async {
      await pumpTile(tester, mode: mode, status: 'unavailable');

      expect(flagDecoration(tester)?.border, isNull);
      expect(find.byKey(const ValueKey('proxy-ping')), findsOneWidget);
      expect(find.byKey(const ValueKey('proxy-ipv6-unavailable-cross')), findsNothing);
    });
  }

  testWidgets('ipv4_only never exposes IPv6 decoration or status semantics', (tester) async {
    await pumpTile(tester, mode: IPv6Mode.disable, status: 'unavailable');

    expect(flagDecoration(tester)?.border, isNull);
    expect(find.byKey(const ValueKey('proxy-ping')), findsOneWidget);
    expect(find.bySemanticsLabel('IPv6 unavailable'), findsNothing);
  });
}
