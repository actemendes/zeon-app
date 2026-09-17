import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/constants.dart';
import 'package:zeon/core/model/region.dart';
import 'package:zeon/core/notification/in_app_notification_controller.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/features/home/widget/world_map_background.dart';
import 'package:zeon/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:zeon/features/mobile/data/mobile_device_rebind_service.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/utils/utils.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

class IntroPage extends HookConsumerWidget with PresLogger {
  const IntroPage({super.key});

  static const double _maxContentWidth = 1120;
  static const bool _bindFeatureEnabled = bool.fromEnvironment('mobile_bind_enabled', defaultValue: true);
  static bool locationInfoLoaded = false;

  // Onboarding uses the map's quiet idle motion without starting VPN observers.
  static final _backgroundState = MainVpnButtonState.fromSnapshot(
    const VpnSessionSnapshot(
      generation: 0,
      runtimeEpoch: 'intro-background',
      sequenceNumber: 0,
      snapshotVersion: 1,
      phase: VpnSessionPhase.idle,
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final breakpoint = Breakpoint(context);
    final logoAsset = theme.brightness == Brightness.dark
        ? 'assets/images/SVG/big-logo-dark.svg'
        : 'assets/images/SVG/big-logo-light.svg';

    final isStarting = useState(false);

    if (!locationInfoLoaded) {
      autoSelectRegion(ref).then((value) => loggy.debug("Auto Region selection finished!"));
      locationInfoLoaded = true;
    }

    return Scaffold(
      key: const ValueKey(UiNames.screenIntro),
      body: Stack(
        children: [
          Positioned.fill(child: WorldMapBackground(state: _backgroundState)),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 840;
                final header = _IntroAppBarTitle(
                  line1: t.intro.appBarLine1,
                  line2: t.intro.appBarLine2,
                  line3: t.intro.appBarLine3,
                  activeBreakpoint: breakpoint.activeBreakpoint,
                );
                final logo = SvgPicture.asset(
                  logoAsset,
                  key: const ValueKey(UiNames.imageIntroLogo),
                  width: wide ? 400 : 300,
                );
                final footer = _IntroFooter(
                  isStarting: isStarting.value,
                  startTitle: t.intro.ctaTitle,
                  startSubtitle: t.intro.ctaSubtitle,
                  accountLabel: t.intro.alreadyHaveAccount,
                  showAccountButton: _bindFeatureEnabled,
                  onStart: () async {
                    if (isStarting.value) return;
                    isStarting.value = true;
                    await ref.read(Preferences.introCompleted.notifier).update(true);
                    if (context.mounted) context.goNamed('home');
                  },
                  onTermsTap: () async {
                    await UriUtils.tryLaunch(Uri.parse(Constants.termsAndConditionsUrl));
                  },
                );
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight),
                    child: Center(
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: _maxContentWidth),
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                        child: wide
                            ? Row(
                                children: [
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsetsDirectional.only(end: 48),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [header, const Gap(64), logo],
                                      ),
                                    ),
                                  ),
                                  Expanded(child: footer),
                                ],
                              )
                            : ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 520),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    header,
                                    SizedBox(
                                      height: (constraints.maxHeight - 470).clamp(200.0, 420.0),
                                      child: Center(
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 24),
                                          child: logo,
                                        ),
                                      ),
                                    ),
                                    footer,
                                  ],
                                ),
                              ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> autoSelectRegion(WidgetRef ref) async {
    try {
      await ref.read(ConfigOptions.region.notifier).update(Region.ru);
      await ref.read(ConfigOptions.directDnsAddress.notifier).reset();
    } catch (e) {
      loggy.warning('Could not set default region', e);
    }
  }
}

class _IntroFooter extends ConsumerWidget {
  const _IntroFooter({
    required this.isStarting,
    required this.startTitle,
    required this.startSubtitle,
    required this.accountLabel,
    required this.showAccountButton,
    required this.onStart,
    required this.onTermsTap,
  });

  final bool isStarting;
  final String startTitle;
  final String startSubtitle;
  final String accountLabel;
  final bool showAccountButton;
  final VoidCallback onStart;
  final VoidCallback onTermsTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final linkColor = theme.brightness == Brightness.dark ? const Color(0xFF91C2FF) : const Color(0xFF245FA8);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _IntroStartButton(isLoading: isStarting, title: startTitle, subtitle: startSubtitle, onPressed: onStart),
            if (showAccountButton) ...[
              const Gap(12),
              _IntroSecondaryButton(label: accountLabel),
              const Gap(16),
            ] else
              const Gap(16),
            Text.rich(
              key: const ValueKey(UiNames.textIntroTermsAndPolicy),
              textAlign: TextAlign.center,
              t.intro.termsAndPolicyCaution(
                tap: (text) => TextSpan(
                  text: text,
                  style: theme.textTheme.bodySmall?.copyWith(color: linkColor, fontWeight: FontWeight.w600),
                  recognizer: TapGestureRecognizer()..onTap = onTermsTap,
                ),
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.brightness == Brightness.dark ? const Color(0xFF989CA3) : const Color(0xFF63707B),
                fontFamily: 'Montserrat',
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IntroStartButton extends StatelessWidget {
  const _IntroStartButton({
    required this.isLoading,
    required this.title,
    required this.subtitle,
    required this.onPressed,
  });

  static const _arrowSize = 24.0;
  static const _arrowVisualScale = 1.0;

  final bool isLoading;
  final String title;
  final String subtitle;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : theme.colorScheme.onSurface;
    final subtitleColor = theme.brightness == Brightness.dark ? const Color(0xFF0F2218) : theme.colorScheme.onSurface;
    final arrowColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : theme.colorScheme.onSurface;
    final crownColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : const Color(0xFF3A444D);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(colors: [theme.colorScheme.primary, theme.colorScheme.secondary]),
        ),
        child: InkWell(
          key: const ValueKey(UiNames.buttonIntroStart),
          onTap: isLoading ? null : onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                _IntroCrownIcon(size: 22, color: crownColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontFamily: 'Unbounded',
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                          color: titleColor,
                          height: 1,
                        ),
                      ),
                      const Gap(5),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'Montserrat',
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: subtitleColor,
                          height: 1,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox.square(
                  dimension: 40,
                  child: Center(
                    child: isLoading
                        ? SizedBox(
                            width: _arrowSize,
                            height: _arrowSize,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              valueColor: AlwaysStoppedAnimation<Color>(arrowColor),
                            ),
                          )
                        : Transform.scale(
                            scale: _arrowVisualScale,
                            child: Icon(Icons.arrow_outward, size: _arrowSize, color: arrowColor),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IntroSecondaryButton extends StatelessWidget {
  const _IntroSecondaryButton({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaceColor = theme.colorScheme.secondaryContainer;
    final textColor = theme.brightness == Brightness.dark ? const Color(0xFFD8DEE6) : theme.colorScheme.onSurface;
    return Material(
      color: surfaceColor,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey(UiNames.buttonIntroAlreadyHaveAccount),
        onTap: () {
          showDialog<void>(context: context, builder: (_) => const _BindAccountCodeDialog());
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Center(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                fontFamily: 'Montserrat',
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BindAccountCodeDialog extends HookConsumerWidget {
  const _BindAccountCodeDialog();

  static const _sampleBindLink = 'https://zeon-vps.link/open/XXXXXX';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final linkController = useTextEditingController();
    final linkFocusNode = useFocusNode();
    final isSubmitting = useState(false);

    useListenable(linkController);

    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          linkFocusNode.requestFocus();
        }
      });
      return null;
    }, [linkFocusNode]);

    bool isValidBindCode(String value) => RegExp('^[A-Za-z0-9_-]{4,}\$').hasMatch(value);

    String? extractBindCode(String rawInput) {
      final input = rawInput.trim();
      if (input.isEmpty) return null;

      final deepLinkMatch = RegExp('/open/([A-Za-z0-9_-]{4,})').firstMatch(input);
      if (deepLinkMatch != null) {
        return deepLinkMatch.group(1);
      }

      final parsed = Uri.tryParse(input);
      if (parsed != null) {
        final bindCodeParam = parsed.queryParameters['bind_code']?.trim();
        if (bindCodeParam != null && isValidBindCode(bindCodeParam)) {
          return bindCodeParam;
        }

        final codeParam = parsed.queryParameters['code']?.trim();
        if (codeParam != null && isValidBindCode(codeParam)) {
          return codeParam;
        }

        final segments = parsed.pathSegments
            .map((segment) => Uri.decodeComponent(segment).trim())
            .where((segment) => segment.isNotEmpty)
            .toList();
        if (segments.isNotEmpty) {
          final openIndex = segments.lastIndexWhere((segment) => segment.toLowerCase() == 'open');
          if (openIndex != -1 && openIndex + 1 < segments.length) {
            final segmentAfterOpen = segments[openIndex + 1];
            if (isValidBindCode(segmentAfterOpen)) {
              return segmentAfterOpen;
            }
          }

          final lastSegment = segments.last;
          if (isValidBindCode(lastSegment)) {
            return lastSegment;
          }
        }
      }

      final normalized = input.replaceAll(RegExp(r'\s+'), '');
      if (isValidBindCode(normalized)) {
        return normalized;
      }

      return null;
    }

    bool isLikelyAccountLink(String rawInput) {
      final input = rawInput.trim();
      if (input.isEmpty) return false;
      final parsed = Uri.tryParse(input);
      if (parsed == null) return false;
      if (parsed.hasScheme && (parsed.scheme == 'http' || parsed.scheme == 'https')) return true;
      return input.contains('/') || input.contains('?');
    }

    final isInputValid = isLikelyAccountLink(linkController.text) || extractBindCode(linkController.text) != null;

    String mapBindError(String code) {
      switch (code.trim()) {
        case "device_already_bound":
          return t.intro.bindErrors.alreadyBound;
        case "bind_link_not_found":
          return t.intro.bindErrors.linkNotFound;
        case "bind_not_configured":
          return t.intro.bindErrors.unavailable;
        case "network_connectionTimeout":
          return t.intro.bindErrors.timeout;
        case "network_connectionError":
          return t.intro.bindErrors.connection;
        case "validation_error":
          return t.intro.bindErrors.invalid;
        default:
          return code.isEmpty ? t.errors.unexpected : code;
      }
    }

    void showError(String message) {
      final notification = ref.read(inAppNotificationControllerProvider);
      notification.showErrorToast(message);
    }

    Future<void> bind() async {
      if (isSubmitting.value) return;
      final rawInput = linkController.text.trim();

      isSubmitting.value = true;
      try {
        final importService = ref.read(mobileConnLinkImportServiceProvider);
        MobileConnLinkImportResult importResult;
        if (isLikelyAccountLink(rawInput) || extractBindCode(rawInput) != null) {
          importResult = await importService
              .importConnectionLink(rawInput, mode: MobileConnLinkImportMode.fast)
              .timeout(const Duration(seconds: 25));
          await ref.read(mobileDeviceRebindServiceProvider).syncManualImportRebind(importResult);
        } else {
          showError(t.errors.profiles.invalidUrl);
          isSubmitting.value = false;
          return;
        }
      } on MobileConnLinkImportException catch (e) {
        if (!context.mounted) return;
        isSubmitting.value = false;
        showError(mapBindError(e.code));
        return;
      } on TimeoutException {
        if (!context.mounted) return;
        isSubmitting.value = false;
        showError(mapBindError("network_connectionTimeout"));
        return;
      } catch (_) {
        if (!context.mounted) return;
        isSubmitting.value = false;
        showError(t.errors.unexpected);
        return;
      }
      isSubmitting.value = false;

      if (!context.mounted) return;

      final notification = ref.read(inAppNotificationControllerProvider);
      notification.showSuccessToast(t.common.done);
      await ref.read(Preferences.introCompleted.notifier).update(true);
      if (!context.mounted) return;

      Navigator.of(context).pop();
      context.goNamed('home');
    }

    final dialogBackgroundColor = theme.brightness == Brightness.dark
        ? const Color(0xFF161B22)
        : const Color(0xFFFFFFFF);
    final titleColor = theme.brightness == Brightness.dark ? const Color(0xFFF1F5F9) : const Color(0xFF1F2937);
    final helperTextColor = theme.brightness == Brightness.dark ? const Color(0xFFB3BFCA) : const Color(0xFF5B6670);
    final inputFillColor = theme.brightness == Brightness.dark ? const Color(0xFF202833) : const Color(0xFFF4F7FA);
    final inputBorderColor = theme.brightness == Brightness.dark ? const Color(0xFF3B4756) : const Color(0xFFC8D3DC);

    return AlertDialog(
      scrollable: true,
      key: const ValueKey(UiNames.dialogIntroBindAccount),
      backgroundColor: dialogBackgroundColor,
      title: Text(
        t.pages.profileDetails.linkAccount.title,
        style: theme.textTheme.titleLarge?.copyWith(
          fontFamily: 'Unbounded',
          fontWeight: FontWeight.w600,
          color: titleColor,
        ),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              key: const ValueKey(UiNames.textIntroBindDescription),
              t.intro.bindAccountDialogDescription,
              style: theme.textTheme.bodySmall?.copyWith(
                color: helperTextColor,
                fontFamily: 'Montserrat',
                fontWeight: FontWeight.w600,
              ),
            ),
            const Gap(16),
            Text(
              key: const ValueKey(UiNames.textIntroBindLinkLabel),
              t.pages.profileDetails.linkAccount.codeLabel,
              style: theme.textTheme.labelLarge?.copyWith(fontFamily: 'Montserrat', fontWeight: FontWeight.w600),
            ),
            const Gap(10),
            SizedBox(
              width: double.infinity,
              child: TextField(
                key: const ValueKey(UiNames.inputIntroBindLink),
                controller: linkController,
                focusNode: linkFocusNode,
                onSubmitted: (_) => bind(),
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'Montserrat',
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                  color: titleColor,
                ),
                decoration: InputDecoration(
                  hintText: _sampleBindLink,
                  hintStyle: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                    color: helperTextColor.withValues(alpha: 0.6),
                  ),
                  filled: true,
                  fillColor: inputFillColor,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: inputBorderColor),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: inputBorderColor),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.8),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actions: [
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const ValueKey(UiNames.buttonIntroBindSubmit),
            onPressed: isSubmitting.value || !isInputValid ? null : bind,
            child: isSubmitting.value
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(t.pages.profileDetails.menu.bindAccount),
          ),
        ),
      ],
    );
  }
}

class _IntroAppBarTitle extends StatelessWidget {
  const _IntroAppBarTitle({
    required this.line1,
    required this.line2,
    required this.line3,
    required this.activeBreakpoint,
  });

  final String line1;
  final String line2;
  final String line3;
  final Breakpoints activeBreakpoint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wide = activeBreakpoint == Breakpoints.desktop;
    final style = theme.textTheme.headlineMedium?.copyWith(
      fontFamily: 'Unbounded',
      fontSize: wide ? 38 : 28,
      fontWeight: FontWeight.w400,
      height: 1.3,
      letterSpacing: -0.8,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(line1, style: style),
        Text(line2, style: style),
        const Gap(12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(14)),
          child: Text(
            line3,
            style: style?.copyWith(
              fontSize: wide ? 32 : 24,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

class _IntroCrownIcon extends StatelessWidget {
  const _IntroCrownIcon({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _IntroCrownPainter(color)),
    );
  }
}

class _IntroCrownPainter extends CustomPainter {
  const _IntroCrownPainter(this.color);

  static const _viewBox = 31.15;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / _viewBox;
    final dx = (size.width - (_viewBox * scale)) / 2;
    final dy = (size.height - (_viewBox * scale)) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);

    final crownPath = Path()
      ..moveTo(1, 30.15)
      ..lineTo(30.15, 30.15)
      ..moveTo(1, 1)
      ..lineTo(1, 23.9)
      ..lineTo(30.15, 23.9)
      ..lineTo(30.15, 1)
      ..lineTo(22.86, 9.33)
      ..lineTo(15.57, 1)
      ..lineTo(8.28, 9.33)
      ..close();

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    canvas.drawPath(crownPath, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _IntroCrownPainter oldDelegate) => oldDelegate.color != color;
}
