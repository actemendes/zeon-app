import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:hiddify/features/home/widget/connection_button.dart';
import 'package:hiddify/features/home/widget/home_premium_access_button.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_card.dart';
import 'package:hiddify/features/proxy/active/active_proxy_delay_indicator.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sliver_tools/sliver_tools.dart';

class HomePage extends HookConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final backgroundMapAsset = theme.brightness == Brightness.dark
        ? 'assets/images/2x/dark-back@2x.png'
        : 'assets/images/2x/light-back@2x.png';
    final t = ref.watch(translationsProvider).requireValue;
    // final hasAnyProfile = ref.watch(hasAnyProfileProvider);
    final activeProfile = ref.watch(activeProfileProvider);
    final breakpoint = Breakpoint(context);
    final subscriptionName = switch (activeProfile) {
      AsyncData(value: final profile?) when profile.name.isNotBlank => profile.name,
      _ => "anonymous",
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Opacity(
                    opacity: 1,
                    child: Image.asset(backgroundMapAsset, height: constraints.maxHeight, fit: BoxFit.fitHeight),
                  ),
                ),
              ),
            ),
            Scaffold(
              backgroundColor: Colors.transparent,
              appBar: AppBar(
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                shadowColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
                toolbarHeight: switch (breakpoint.activeBreakpoint) {
                  Breakpoints.mobile => 164,
                  Breakpoints.tablet => 132,
                  Breakpoints.desktop => 132,
                },
                centerTitle: false,
                titleSpacing: 0,
                actionsPadding: EdgeInsets.zero,
                // leading: (RootScaffold.stateKey.currentState?.hasDrawer ?? false) && showDrawerButton(context)
                //     ? DrawerButton(
                //         onPressed: () {
                //           RootScaffold.stateKey.currentState?.openDrawer();
                //         },
                //       )
                //     : null,
                title: const SizedBox.shrink(),
                flexibleSpace: SafeArea(
                  bottom: false,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Align(
                        alignment: Alignment.topLeft,
                        child: _HomeAppBarTitle(
                          activeBreakpoint: breakpoint.activeBreakpoint,
                          internetLabel: t.pages.home.internet,
                          forYouLabel: t.pages.home.forYou,
                          subscriptionName: subscriptionName,
                        ),
                      ),
                      Positioned(
                        top: 20,
                        right: 20,
                        child: Semantics(
                          key: const ValueKey("profile_quick_settings"),
                          label: t.pages.home.quickSettings,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(width: 22, height: 20),
                            icon: Icon(Icons.tune_rounded, color: theme.colorScheme.onSurface),
                            onPressed: () => ref.read(bottomSheetsNotifierProvider.notifier).showQuickSettings(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              body: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 600, // Set the maximum width here
                  ),
                  child: CustomScrollView(
                    slivers: [
                      MultiSliver(
                        children: const [
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [ConnectionButton(), ActiveProxyDelayIndicator()],
                                  ),
                                ),
                                ActiveProxyFooter(),
                                HomePremiumAccessButton(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _HomeAppBarTitle extends StatelessWidget {
  const _HomeAppBarTitle({
    required this.activeBreakpoint,
    required this.internetLabel,
    required this.forYouLabel,
    required this.subscriptionName,
  });

  final Breakpoints activeBreakpoint;
  final String internetLabel;
  final String forYouLabel;
  final String subscriptionName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headingStyle = theme.textTheme.titleLarge?.copyWith(
      fontFamily: "Unbounded",
      fontWeight: FontWeight.w300,
      fontSize: 32,
      height: 27 / 32,
    );
    final nameStyle = theme.textTheme.titleLarge?.copyWith(
      fontFamily: "Unbounded",
      fontWeight: FontWeight.w700,
      fontSize: 32,
      height: 37 / 32,
    );
    final subscriptionUpper = subscriptionName.toUpperCase();

    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 20),
      child: switch (activeBreakpoint) {
        Breakpoints.mobile => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(internetLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: headingStyle),
            Text(forYouLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: headingStyle),
            Text(subscriptionUpper, maxLines: 2, overflow: TextOverflow.ellipsis, style: nameStyle),
          ],
        ),
        Breakpoints.tablet || Breakpoints.desktop => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$internetLabel $forYouLabel', maxLines: 1, overflow: TextOverflow.ellipsis, style: headingStyle),
            Text(subscriptionUpper, maxLines: 2, overflow: TextOverflow.ellipsis, style: nameStyle),
          ],
        ),
      },
    );
  }
}

class AppVersionLabel extends HookConsumerWidget {
  const AppVersionLabel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    final version = ref.watch(appInfoProvider).requireValue.presentVersion;
    if (version.isBlank) return const SizedBox();

    return Semantics(
      label: t.common.version,
      button: false,
      child: Container(
        decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(4)),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(
          version,
          textDirection: TextDirection.ltr,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
        ),
      ),
    );
  }
}
