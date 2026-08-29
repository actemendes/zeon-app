import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/proxy/active/active_proxy_card.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

void main() {
  testWidgets('connected Home keeps a visible picker while the server resolves', (tester) async {
    await _pumpFooter(tester, status: const Connected(), activeProxy: const AsyncLoading());

    expect(find.byKey(const ValueKey('home_server_picker')), findsOneWidget);
    expect(find.byKey(const ValueKey('home_server_picker_loading')), findsOneWidget);
  });

  testWidgets('disconnected Home keeps a meaningful picker placeholder', (tester) async {
    await _pumpFooter(tester, status: const Disconnected(), activeProxy: const AsyncLoading());

    expect(find.byKey(const ValueKey('home_server_picker')), findsOneWidget);
    expect(find.byKey(const ValueKey('home_server_picker_unavailable')), findsOneWidget);
  });

  testWidgets('resolved server replaces the placeholder without removing the picker', (tester) async {
    await _pumpFooter(
      tester,
      status: const Connected(),
      activeProxy: AsyncData(
        OutboundInfo(
          tag: 'server-stable-id',
          tagDisplay: 'Test Server',
          type: 'proxy',
          isVisible: true,
          urlTestDelay: 42,
        ),
      ),
    );

    expect(find.byKey(const ValueKey('home_server_picker')), findsOneWidget);
    expect(find.text('Test Server'), findsOneWidget);
    expect(find.byKey(const ValueKey('home_server_picker_loading')), findsNothing);
  });
}

Future<void> _pumpFooter(
  WidgetTester tester, {
  required ConnectionStatus status,
  required AsyncValue<OutboundInfo> activeProxy,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        translationsProvider.overrideWith((ref) => TranslationsEn()),
        connectionNotifierProvider.overrideWith(() => _FixedConnectionNotifier(status)),
      ],
      child: MaterialApp(
        home: Scaffold(body: ActiveProxyFooter(activeProxy: activeProxy)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

class _FixedConnectionNotifier extends ConnectionNotifier {
  _FixedConnectionNotifier(this.status);

  final ConnectionStatus status;

  @override
  Stream<ConnectionStatus> build() => Stream.value(status);
}
