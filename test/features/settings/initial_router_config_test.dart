import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/core/router/deep_linking/my_app_links.dart';
import 'package:zeon/core/router/go_router/go_router_notifier.dart';
import 'package:zeon/core/router/go_router/routing_config_notifier.dart';

class _ReadyRoutes extends RoutingConfigNotifier {
  @override
  RoutingConfig build() => RoutingConfig(
    routes: [GoRoute(name: 'home', path: '/home', builder: (_, _) => const Text('ready watch route'))],
  );
}

void main() {
  testWidgets('already resolved routes appear without a subsequent breakpoint change', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    GoRouterNotifer.rConfig.value = loadingConfig;
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((_) => prefs),
        myAppLinksProvider.overrideWith((_) => const Stream.empty()),
        routingConfigNotifierProvider.overrideWith(_ReadyRoutes.new),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);
    final router = container.read(goRouterNotiferProvider);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    expect(find.text('ready watch route'), findsOneWidget);
  });
}
