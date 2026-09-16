import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:zeon/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/features/home/notifier/home_connection_state_provider.dart';
import 'package:zeon/features/home/widget/connection_button.dart';
import 'package:zeon/features/home/widget/home_connection_layout.dart';
import 'package:zeon/features/home/widget/home_premium_access_button.dart';
import 'package:zeon/features/home/widget/world_map_background.dart';
import 'package:zeon/features/home_tips/home_tip_card.dart';
import 'package:zeon/features/home_tips/home_tip_provider.dart';
import 'package:zeon/features/profile/data/profile_name_parser.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/profile/notifier/profile_notifier.dart';
import 'package:zeon/features/proxy/active/active_proxy_card.dart';
import 'package:zeon/features/proxy/active/active_proxy_delay_indicator.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/utils/platform_utils.dart';

class HomePage extends HookConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tip = ref.watch(homeTipProvider);
    useEffect(() {
      Future.microtask(() => ref.read(homeTipProvider.notifier).refresh());
      return null;
    }, const []);
    final buttonFaceKey = useMemoized(() => GlobalKey());
    final tipAnchor = useMemoized(() => LayerLink());
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
              body: SafeArea(
                child: _HomeConnectionBody(
                  buttonFaceKey: buttonFaceKey,
                  desktop: breakpoint.isDesktop(),
                  secure: _hasSecureConnection(ref),
                  tablet: breakpoint.isTablet(),
                  header: _HomeHeaderFrame(
                    mobile: breakpoint.isMobile(),
                    child: Row(
                      crossAxisAlignment: breakpoint.isMobile() ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _HomeAppBarTitle(
                            activeBreakpoint: breakpoint.activeBreakpoint,
                            internetLabel: t.pages.home.internet,
                            forYouLabel: t.pages.home.forYou,
                            subscriptionName: subscriptionName,
                            tipAnchor: tipAnchor,
                          ),
                        ),
                        SizedBox(width: breakpoint.isMobile() ? 12 : 16),
                        IconButton(
                          key: const ValueKey('home_refresh'),
                          tooltip: t.common.update,
                          style: IconButton.styleFrom(
                            backgroundColor: breakpoint.isMobile()
                                ? theme.colorScheme.surface
                                : theme.colorScheme.secondaryContainer,
                            fixedSize: const Size(48, 48),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
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
                            child: Icon(Icons.refresh_rounded, size: 22, color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (tip != null)
              Positioned.fill(
                child: CompositedTransformFollower(
                  link: tipAnchor,
                  showWhenUnlinked: false,
                  targetAnchor: Alignment.bottomLeft,
                  offset: const Offset(0, 8),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: (constraints.maxWidth - 32).clamp(0.0, compactHeight ? 240.0 : 360.0),
                      child: HomeTipCard(content: tip, padding: EdgeInsets.zero),
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
  const _HomeConnectionBody({
    required this.buttonFaceKey,
    required this.desktop,
    required this.secure,
    required this.tablet,
    required this.header,
  });
  final GlobalKey buttonFaceKey;
  final bool desktop;
  final bool secure;
  final bool tablet;
  final Widget header;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      return SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: HomeConnectionLayout(
          key: const ValueKey('home_canvas'),
          viewportHeight: constraints.maxHeight,
          desktop: desktop,
          header: header,
          dial: ConnectionButton(faceKey: buttonFaceKey, showStatus: false),
          status: desktop
              ? const _HomeConnectionPanel()
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [const _HomeMobileStatus(), if (secure) const _HomeSecureCaption()],
                  ),
                ),
          footer: desktop
              ? const SizedBox.shrink()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (PlatformUtils.isWindows)
                      _HomeQuickSettingsButton(label: MaterialLocalizations.of(context).showMenuTooltip),
                    const ActiveProxyFooter(margin: EdgeInsets.zero),
                    if (tablet) ...[
                      const SizedBox(height: 12),
                      const HomePremiumAccessButton(padding: EdgeInsets.zero),
                    ],
                  ],
                ),
        ),
      );
    },
  );
}

bool _hasSecureConnection(WidgetRef ref) {
  final delay = ref.watch(activeProxyNotifierProvider).valueOrNull?.urlTestDelay ?? 0;
  return ref.watch(homeConnectionStateProvider).isConnected &&
      delay > 0 &&
      delay < 65000 &&
      ref.watch(ConfigOptions.enableWarp) &&
      ref.watch(ConfigOptions.warpDetourMode) == WarpDetourMode.warpOverProxy;
}

class _HomeSecureCaption extends ConsumerWidget {
  const _HomeSecureCaption();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final t = ref.watch(translationsProvider).requireValue;
    return Padding(
      key: const ValueKey('home_secure_caption'),
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.shield_outlined, size: 16, color: cs.secondary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              t.connection.secure,
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: 'Montserrat', fontSize: 14, height: 1.5, color: cs.secondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeMobileStatus extends ConsumerWidget {
  const _HomeMobileStatus();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final state = ref.watch(homeConnectionStateProvider);
    final t = ref.watch(translationsProvider).requireValue;
    return Container(
      key: const ValueKey('home_mobile_status'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(99)),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 14,
        runSpacing: 8,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: state.isConnected ? cs.primary : cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 9),
              Flexible(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    state.present(t).label.replaceAll('\n', ' '),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Montserrat',
                      fontSize: 16,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (state.isConnected) const ActiveProxyDelayIndicator(compact: true),
        ],
      ),
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
        style: (theme.navigationBarTheme.labelTextStyle?.resolve(const <WidgetState>{}) ?? theme.textTheme.labelMedium)
            ?.copyWith(fontFamily: 'Montserrat', height: 1.5, fontWeight: FontWeight.w600),
      ),
    );
    final quickSettings = _HomeQuickSettingsButton(label: t.pages.home.quickSettings, embedded: true);

    final content = Padding(
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
                        child: Align(alignment: Alignment.centerLeft, child: ActiveProxyDelayIndicator(compact: true)),
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
            ActiveProxyFooter(desktop: true, margin: EdgeInsets.zero, backgroundColor: theme.colorScheme.surface),
          ],
          const SizedBox(height: 12),
          const HomePremiumAccessButton(padding: EdgeInsets.zero),
        ],
      ),
    );

    return Material(
      key: const ValueKey('home_desktop_connection_panel'),
      color: theme.colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(34),
      clipBehavior: Clip.antiAlias,
      child: reduceMotion
          ? content
          : AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topCenter,
              child: content,
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

class _HomeHeaderFrame extends StatelessWidget {
  const _HomeHeaderFrame({required this.mobile, required this.child});
  final bool mobile;
  final Widget child;

  @override
  Widget build(BuildContext context) => mobile
      ? Container(
          key: const ValueKey('home_header_panel'),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(24),
          ),
          child: child,
        )
      : child;
}

class _HomeAppBarTitle extends StatelessWidget {
  const _HomeAppBarTitle({
    required this.activeBreakpoint,
    required this.internetLabel,
    required this.forYouLabel,
    required this.subscriptionName,
    required this.tipAnchor,
  });
  final Breakpoints activeBreakpoint;
  final String internetLabel;
  final String forYouLabel;
  final String subscriptionName;
  final LayerLink tipAnchor;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mobile = activeBreakpoint == Breakpoints.mobile;
    final headerStyle = TextStyle(
      fontFamily: 'Unbounded',
      fontSize: 18,
      height: 1.15,
      fontWeight: FontWeight.w600,
      color: cs.onSurface,
    );
    return Column(
      key: const ValueKey('home_header_text'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$internetLabel $forYouLabel'.toUpperCase(),
          style: mobile ? headerStyle.copyWith(fontSize: 14, fontWeight: FontWeight.w400) : headerStyle,
        ),
        SizedBox(
          height: mobile
              ? 2
              : activeBreakpoint == Breakpoints.desktop
              ? 3
              : 8,
        ),
        CompositedTransformTarget(
          link: tipAnchor,
          child: Text(
            subscriptionName.toUpperCase(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: mobile
                ? headerStyle.copyWith(fontSize: 20, fontWeight: FontWeight.w700)
                : headerStyle.copyWith(fontSize: 32, height: 1.05, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}
