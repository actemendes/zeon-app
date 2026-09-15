import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/proxy/active/active_proxy_card.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

void main() {
  testWidgets('disconnected Home does not render the server picker', (tester) async {
    await _pumpFooter(
      tester,
      status: const Disconnected(),
      activeProxy: OutboundInfo(tag: 'server-a', tagDisplay: 'Server A', type: 'proxy', isVisible: true),
    );

    expect(find.byKey(const ValueKey('home_server_picker')), findsNothing);
  });

  testWidgets('connected Home keeps the picker visible while the runtime leaf resolves', (tester) async {
    await _pumpFooter(tester, status: const Connected());

    expect(find.byKey(const ValueKey('home_server_picker')), findsOneWidget);
    expect(find.byKey(const ValueKey('home_server_picker_loading')), findsOneWidget);
  });

  testWidgets('connected Home shows the runtime server name when resolved', (tester) async {
    await _pumpFooter(
      tester,
      status: const Connected(),
      activeProxy: OutboundInfo(tag: 'server-a', tagDisplay: 'Server A', type: 'proxy', isVisible: true),
    );

    expect(find.byKey(const ValueKey('home_server_picker')), findsOneWidget);
    expect(find.text('Server A'), findsOneWidget);
    expect(find.byKey(const ValueKey('home_server_picker_loading')), findsNothing);
  });
}

Future<void> _pumpFooter(WidgetTester tester, {required ConnectionStatus status, OutboundInfo? activeProxy}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        translationsProvider.overrideWith((ref) => TranslationsEn()),
        connectionNotifierProvider.overrideWith(() => _FixedConnectionNotifier(status)),
        activeProxyNotifierProvider.overrideWith(() => _FixedActiveProxyNotifier(activeProxy)),
      ],
      child: const MaterialApp(home: Scaffold(body: ActiveProxyFooter())),
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

class _FixedActiveProxyNotifier extends ActiveProxyNotifier {
  _FixedActiveProxyNotifier(this.activeProxy);

  final OutboundInfo? activeProxy;

  @override
  Stream<OutboundInfo> build() => activeProxy == null ? const Stream.empty() : Stream.value(activeProxy!);
}
