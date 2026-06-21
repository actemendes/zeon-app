import 'package:dartx/dartx.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:hiddify/core/ui/ui_names.dart';
import 'package:hiddify/features/home/widget/connection_button.dart';
import 'package:hiddify/features/home/widget/home_premium_access_button.dart';
import 'package:hiddify/features/profile/data/profile_name_parser.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_card.dart';
import 'package:hiddify/features/proxy/active/active_proxy_delay_indicator.dart';
import 'package:hiddify/utils/platform_utils.dart';
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
    final isUpdatingProfile = switch (activeProfile.valueOrNull) {
      RemoteProfileEntity(:final id) => ref.watch(updateProfileNotifierProvider(id)).isLoading,
      _ => false,
    };
    final refreshAnimationController = useAnimationController(duration: const Duration(milliseconds: 900));
    useEffect(() {
      if (isUpdatingProfile) {
        refreshAnimationController.repeat();
      } else {
        refreshAnimationController
          ..stop()
          ..reset();
      }
      return null;
    }, [isUpdatingProfile, refreshAnimationController]);
    final breakpoint = Breakpoint(context);
    final subscriptionName = switch (activeProfile) {
      AsyncData(value: final profile?) when parseProfileName(profile.name).isNotBlank => parseProfileName(profile.name),
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
              key: const ValueKey(UiNames.screenHome),
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
                        child: IconButton(
                          tooltip: 'Обновить подписку',
                          padding: EdgeInsets.zero,
                          iconSize: 24,
                          constraints: const BoxConstraints.tightFor(width: 24, height: 24),
                          onPressed: isUpdatingProfile
                              ? null
                              : () async {
                                  final active = await ref.read(activeProfileProvider.future);
                                  if (active is! RemoteProfileEntity) return;
                                  await ref
                                      .read(updateProfileNotifierProvider(active.id).notifier)
                                      .updateProfile(active);
                                },
                          icon: RotationTransition(
                            turns: refreshAnimationController,
                            child: SizedBox.square(
                              dimension: 24,
                              child: Icon(FluentIcons.arrow_sync_24_regular, color: theme.colorScheme.onSurface),
                            ),
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
                        children: [
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [ConnectionButton(), ActiveProxyDelayIndicator()],
                                  ),
                                ),
                                _HomeQuickSettingsButton(label: t.pages.home.quickSettings),
                                const ActiveProxyFooter(),
                                const HomePremiumAccessButton(),
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

class _HomeQuickSettingsButton extends ConsumerWidget {
  const _HomeQuickSettingsButton({required this.label});

  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!PlatformUtils.isWindows) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final backgroundColor = theme.navigationBarTheme.backgroundColor ?? theme.colorScheme.surface;
    final foregroundColor =
        theme.navigationBarTheme.iconTheme?.resolve(const <WidgetState>{})?.color ?? theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Align(
        alignment: Alignment.centerRight,
        child: Semantics(
          key: const ValueKey("profile_quick_settings"),
          label: label,
          button: true,
          child: Material(
            color: backgroundColor,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: Tooltip(
              message: label,
              preferBelow: false,
              child: IconButton(
                iconSize: 20,
                constraints: const BoxConstraints.tightFor(width: 40, height: 40),
                padding: EdgeInsets.zero,
                icon: Icon(Icons.vpn_key, color: foregroundColor),
                onPressed: () => ref.read(bottomSheetsNotifierProvider.notifier).showQuickSettings(),
              ),
            ),
          ),
        ),
      ),
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
    const headingLineHeight = 27 / 32;
    const subscriptionTopSpacing = 6.0;
    final headingStyle = theme.textTheme.titleLarge?.copyWith(
      fontFamily: "Unbounded",
      fontWeight: FontWeight.w300,
      fontSize: 32,
      height: headingLineHeight,
    );
    final nameStyle = theme.textTheme.titleLarge?.copyWith(
      fontFamily: "Unbounded",
      fontWeight: FontWeight.w700,
      fontSize: 32,
      height: headingLineHeight,
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
            const SizedBox(height: subscriptionTopSpacing),
            Text(subscriptionUpper, maxLines: 2, overflow: TextOverflow.ellipsis, style: nameStyle),
          ],
        ),
        Breakpoints.tablet || Breakpoints.desktop => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$internetLabel $forYouLabel', maxLines: 1, overflow: TextOverflow.ellipsis, style: headingStyle),
            const SizedBox(height: subscriptionTopSpacing),
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
