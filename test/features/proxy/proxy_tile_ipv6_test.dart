import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/features/proxy/widget/proxy_tile.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

void main() {
  testWidgets('proxy tile exposes the IPv6 capability state', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [translationsProvider.overrideWith((ref) => TranslationsEn())],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: ProxyTile(
                OutboundInfo(tag: 'node', tagDisplay: 'Node', ipv6Status: 'supported'),
                selected: false,
                isActive: false,
                countryCode: 'US',
                ipv6Status: 'supported',
                ipv6StatusText: 'IPv6 ✓',
                onTap: null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('IPv6 ✓'), findsOneWidget);
  });
}
