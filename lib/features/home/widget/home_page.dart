import 'package:dartx/dartx.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sliver_tools/sliver_tools.dart';
import 'package:zeon/core/app_info/app_info_provider.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:zeon/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/features/home/notifier/home_connection_state_provider.dart';
import 'package:zeon/features/home/widget/connection_button.dart';
import 'package:zeon/features/home/widget/home_premium_access_button.dart';
import 'package:zeon/features/home/widget/world_map_background.dart';
import 'package:zeon/features/profile/data/profile_name_parser.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/profile/notifier/profile_notifier.dart';
import 'package:zeon/features/proxy/active/active_proxy_card.dart';
import 'package:zeon/features/proxy/active/active_proxy_delay_indicator.dart';
import 'package:zeon/utils/platform_utils.dart';

class HomePage extends HookConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final buttonFaceKey = useMemoized(() => GlobalKey());
    final connectionState = ref.watch(homeConnectionStateProvider);
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
    final compactHeight = breakpoint.isCompactHeight();
    final textScaler = MediaQuery.textScalerOf(context);
    final subscriptionName = switch (activeProfile) {
      AsyncData(value: final profile?) when parseProfileName(profile.name).isNotBlank => parseProfileName(profile.name),
      _ => "anonymous",
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            Positioned.fill(
              child: WorldMapBackground(state: connectionState, buttonKey: buttonFaceKey),
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
                toolbarHeight: compactHeight
                    ? (30 + textScaler.scale(14) * 1.1 + textScaler.scale(22) * 1.1)
                          .clamp(72.0, double.infinity)
                          .toDouble()
                    : switch (breakpoint.activeBreakpoint) {
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
                          compact: compactHeight,
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
              body: breakpoint.isDesktop() || compactHeight
                  ? _HomeConnectionBody(buttonFaceKey: buttonFaceKey, compactHeight: compactHeight)
                  : Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: breakpoint.isDesktop() ? 600 : double.infinity),
                        child: CustomScrollView(
                          slivers: [
                            MultiSliver(
                              children: [
                                SliverFillRemaining(
                                  hasScrollBody: false,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            ConnectionButton(faceKey: buttonFaceKey),
                                            const ActiveProxyDelayIndicator(),
                                          ],
                                        ),
                                      ),
                                      _HomeQuickSettingsButton(label: t.pages.home.quickSettings),
                                      const ActiveProxyFooter(),
                                      if (!breakpoint.isMobile()) const HomePremiumAccessButton(),
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

class _HomeConnectionBody extends StatelessWidget {
  const _HomeConnectionBody({required this.buttonFaceKey, required this.compactHeight});

  final GlobalKey buttonFaceKey;
  final bool compactHeight;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = compactHeight ? 16.0 : 24.0;
        final availableWidth = constraints.maxWidth - padding * 2;
        final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, double.infinity);
        final minimumPanelWidth = 320 * textScale;
        final buttonSize = constraints.maxHeight >= 192 && availableWidth >= 160 + 24 + minimumPanelWidth
            ? 160.0
            : 140.0;
        final horizontal = compactHeight && availableWidth >= buttonSize + 24 + minimumPanelWidth;
        final button = compactHeight
            ? SizedBox.square(
                dimension: buttonSize,
                child: FittedBox(child: ConnectionButton(faceKey: buttonFaceKey, showStatus: false)),
              )
            : ConnectionButton(faceKey: buttonFaceKey, showStatus: false);

        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(padding),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: horizontal ? buttonSize + 24 + 440 : 440),
                  child: horizontal
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            button,
                            const SizedBox(width: 24),
                            const Flexible(child: _HomeConnectionPanel()),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            button,
                            SizedBox(height: compactHeight ? 16 : 32),
                            const _HomeConnectionPanel(),
                          ],
                        ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HomeConnectionPanel extends ConsumerWidget {
  const _HomeConnectionPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    final connectionState = ref.watch(homeConnectionStateProvider);
    final isConnected = connectionState.isConnected;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final status = Semantics(
      liveRegion: true,
      child: Text(
        connectionState.present(t).label.replaceAll('\n', ' '),
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleSmall?.copyWith(fontFamily: 'Montserrat', fontWeight: FontWeight.w500),
      ),
    );
    final quickSettings = _HomeQuickSettingsButton(label: t.pages.home.quickSettings, embedded: true);

    return Material(
      key: const ValueKey('home_desktop_connection_panel'),
      color: theme.navigationBarTheme.backgroundColor ?? theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(34),
      clipBehavior: Clip.antiAlias,
      child: AnimatedSize(
        key: ValueKey(reduceMotion),
        duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 240),
        curve: Curves.easeInOutCubic,
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 40),
                child: Row(
                  children: isConnected
                      ? [
                          const Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: FittedBox(fit: BoxFit.scaleDown, child: ActiveProxyDelayIndicator(compact: true)),
                            ),
                          ),
                          Expanded(flex: 2, child: status),
                          Expanded(
                            child: Align(alignment: Alignment.centerRight, child: quickSettings),
                          ),
                        ]
                      : [const SizedBox(width: 40), Expanded(child: status), SizedBox(width: 40, child: quickSettings)],
                ),
              ),
              if (isConnected) ...[
                const SizedBox(height: 12),
                ActiveProxyFooter(margin: EdgeInsets.zero, backgroundColor: theme.colorScheme.surface),
              ],
              const SizedBox(height: 12),
              const HomePremiumAccessButton(padding: EdgeInsets.zero),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeQuickSettingsButton extends ConsumerWidget {
  const _HomeQuickSettingsButton({required this.label, this.embedded = false});

  final String label;
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!PlatformUtils.isWindows) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final backgroundColor = theme.navigationBarTheme.backgroundColor ?? theme.colorScheme.surface;
    final foregroundColor =
        theme.navigationBarTheme.iconTheme?.resolve(const <WidgetState>{})?.color ?? theme.colorScheme.onSurface;

    return Padding(
      padding: embedded ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 16),
      child: Align(
        alignment: Alignment.centerRight,
        widthFactor: embedded ? 1 : null,
        heightFactor: embedded ? 1 : null,
        child: Semantics(
          key: const ValueKey("profile_quick_settings"),
          label: label,
          button: true,
          child: Material(
            color: embedded ? theme.colorScheme.surface : backgroundColor,
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
    this.compact = false,
  });

  final Breakpoints activeBreakpoint;
  final String internetLabel;
  final String forYouLabel;
  final String subscriptionName;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const headingLineHeight = 27 / 32;
    const subscriptionTopSpacing = 6.0;
    final headingStyle = theme.textTheme.titleLarge?.copyWith(
      fontFamily: "Unbounded",
      fontWeight: FontWeight.w300,
      fontSize: 18,
      height: headingLineHeight,
    );
    final nameStyle = theme.textTheme.titleLarge?.copyWith(
      fontFamily: "Unbounded",
      fontWeight: FontWeight.w700,
      fontSize: 32,
      height: headingLineHeight,
    );
    final subscriptionUpper = subscriptionName.toUpperCase();

    if (compact) {
      return Padding(
        padding: const EdgeInsets.only(left: 16, top: 12, right: 56),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$internetLabel $forYouLabel',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: headingStyle?.copyWith(fontSize: 14, height: 1.1),
            ),
            const SizedBox(height: subscriptionTopSpacing),
            Text(
              subscriptionUpper,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: nameStyle?.copyWith(fontSize: 22, height: 1.1),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 20),
      child: switch (activeBreakpoint) {
        Breakpoints.mobile => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$internetLabel $forYouLabel', maxLines: 1, overflow: TextOverflow.ellipsis, style: headingStyle),
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
