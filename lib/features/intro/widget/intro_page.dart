import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/localization/locale_preferences.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/region.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:hiddify/features/mobile/data/mobile_bind_service.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class IntroPage extends HookConsumerWidget with PresLogger {
  const IntroPage({super.key});

  static const double _maxContentWidth = 620;
  static const bool _bindFeatureEnabled = bool.fromEnvironment('mobile_bind_enabled', defaultValue: true);
  static bool locationInfoLoaded = false;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final breakpoint = Breakpoint(context);
    final baseBackgroundColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : const Color(0xFFE4ECEF);
    final backgroundMapAsset = theme.brightness == Brightness.dark
        ? 'assets/images/2x/dark-back@2x.png'
        : 'assets/images/2x/light-back@2x.png';
    final logoAsset = theme.brightness == Brightness.dark
        ? 'assets/images/SVG/big-logo-dark.svg'
        : 'assets/images/SVG/big-logo-light.svg';

    final isStarting = useState(false);

    if (!locationInfoLoaded) {
      autoSelectRegion(ref).then((value) => loggy.debug("Auto Region selection finished!"));
      locationInfoLoaded = true;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final logoWidth = switch (breakpoint.activeBreakpoint) {
          Breakpoints.mobile => (constraints.maxWidth * 0.76).clamp(230.0, 360.0),
          Breakpoints.tablet => (constraints.maxWidth * 0.56).clamp(320.0, 480.0),
          Breakpoints.desktop => 440.0,
        };
        return Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: baseBackgroundColor)),
            Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Image.asset(backgroundMapAsset, height: constraints.maxHeight, fit: BoxFit.fitHeight),
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
                  Breakpoints.tablet || Breakpoints.desktop => 132,
                },
                centerTitle: false,
                titleSpacing: 0,
                actionsPadding: EdgeInsets.zero,
                title: const SizedBox.shrink(),
                flexibleSpace: SafeArea(
                  bottom: false,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: _maxContentWidth),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: _IntroAppBarTitle(
                          line1: t.intro.appBarLine1,
                          line2: t.intro.appBarLine2,
                          line3: t.intro.appBarLine3,
                          activeBreakpoint: breakpoint.activeBreakpoint,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              body: SafeArea(
                top: false,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: _maxContentWidth),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                      child: Column(
                        children: [
                          Expanded(
                            child: Center(child: SvgPicture.asset(logoAsset, width: logoWidth)),
                          ),
                          _IntroFooter(
                            isStarting: isStarting.value,
                            startTitle: t.intro.ctaTitle,
                            startSubtitle: t.intro.ctaSubtitle,
                            accountLabel: t.intro.alreadyHaveAccount,
                            showAccountButton: _bindFeatureEnabled,
                            onStart: () async {
                              if (isStarting.value) return;
                              isStarting.value = true;
                              await ref.read(Preferences.introCompleted.notifier).update(true);
                              if (context.mounted) {
                                context.goNamed('home');
                              }
                            },
                            onTermsTap: () async {
                              await UriUtils.tryLaunch(Uri.parse(Constants.termsAndConditionsUrl));
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> autoSelectRegion(WidgetRef ref) async {
    try {
      final countryCode = RegionDetector.detect();
      final regionLocale = _getRegionLocale(countryCode);
      loggy.debug('Timezone Region: ${regionLocale.region} Locale: ${regionLocale.locale}');
      await ref.read(ConfigOptions.region.notifier).update(regionLocale.region);
      await ref.watch(ConfigOptions.directDnsAddress.notifier).reset();
      await ref.read(localePreferencesProvider.notifier).changeLocale(regionLocale.locale);
      return;
    } catch (e) {
      loggy.warning('Could not get the local country code based on timezone', e);
    }

    try {
      final DioHttpClient client = DioHttpClient(
        timeout: const Duration(seconds: 2),
        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:123.0) Gecko/20100101 Firefox/123.0",
        debug: true,
      );
      final response = await client.get<Map<String, dynamic>>('https://api.ip.sb/geoip/');

      if (response.statusCode == 200) {
        final jsonData = response.data!;
        final regionLocale = _getRegionLocale(jsonData['country_code']?.toString() ?? "");

        loggy.debug('Region: ${regionLocale.region} Locale: ${regionLocale.locale}');
        await ref.read(ConfigOptions.region.notifier).update(regionLocale.region);
        await ref.read(localePreferencesProvider.notifier).changeLocale(regionLocale.locale);
      } else {
        loggy.warning('Request failed with status: ${response.statusCode}');
      }
    } catch (e) {
      loggy.warning('Could not get the local country code from ip');
    }
  }

  RegionLocale _getRegionLocale(String country) {
    switch (country.toUpperCase()) {
      case "IR":
        return RegionLocale(Region.ir, AppLocale.fa);
      case "CN":
        return RegionLocale(Region.cn, AppLocale.zhCn);
      case "RU":
        return RegionLocale(Region.ru, AppLocale.ru);
      case "AF":
        return RegionLocale(Region.af, AppLocale.fa);
      case "BR":
        return RegionLocale(Region.br, AppLocale.ptBr);
      case "TR":
        return RegionLocale(Region.tr, AppLocale.tr);
      default:
        return RegionLocale(Region.other, AppLocale.en);
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _IntroStartButton(isLoading: isStarting, title: startTitle, subtitle: startSubtitle, onPressed: onStart),
        if (showAccountButton) ...[
          const Gap(16),
          _IntroSecondaryButton(label: accountLabel),
          const Gap(16),
        ] else
          const Gap(16),
        Text.rich(
          textAlign: TextAlign.center,
          t.intro.termsAndPolicyCaution(
            tap: (text) => TextSpan(
              text: text,
              style: theme.textTheme.bodySmall?.copyWith(color: linkColor, fontWeight: FontWeight.w500),
              recognizer: TapGestureRecognizer()..onTap = onTermsTap,
            ),
          ),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.brightness == Brightness.dark ? const Color(0xFF989CA3) : const Color(0xFF63707B),
            fontFamily: 'Montserrat',
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
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

  static const double _height = 65;
  static const double _leftSegmentWidth = 65;
  static const double _crownPadding = 18;
  static const double _crownSize = 29;
  static const _backgroundAsset = 'assets/images/1x/cta-background.png';
  static const _arrowSize = 24.0;
  static const _arrowVisualScale = 1.18;

  final bool isLoading;
  final String title;
  final String subtitle;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : const Color(0xFF3B444D);
    final subtitleColor = theme.brightness == Brightness.dark ? const Color(0xFF0F2218) : const Color(0xFF3B444D);
    final arrowColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : const Color(0xFF3B444D);
    final crownColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : const Color(0xFF3A444D);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        height: _height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          image: const DecorationImage(image: AssetImage(_backgroundAsset), fit: BoxFit.cover),
        ),
        child: InkWell(
          onTap: isLoading ? null : onPressed,
          child: Row(
            children: [
              Container(
                width: _leftSegmentWidth,
                height: _height,
                color: Colors.transparent,
                padding: const EdgeInsets.all(_crownPadding),
                child: _IntroCrownIcon(size: _crownSize, color: crownColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontFamily: 'Unbounded',
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                        color: titleColor,
                        height: 1,
                      ),
                    ),
                    const Gap(7),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'Montserrat',
                        fontWeight: FontWeight.w500,
                        fontSize: 14,
                        color: subtitleColor,
                        height: 1,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox.square(
                dimension: 44,
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
    );
  }
}

class _IntroSecondaryButton extends StatelessWidget {
  const _IntroSecondaryButton({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaceColor = theme.brightness == Brightness.dark ? const Color(0xFF1A1B1F) : const Color(0xFFD6E1E5);
    final textColor = theme.brightness == Brightness.dark ? const Color(0xFFD8DEE6) : const Color(0xFF3B444D);
    return Material(
      color: surfaceColor,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          showDialog<void>(context: context, builder: (_) => const _BindAccountCodeDialog());
        },
        child: SizedBox(
          height: 44,
          child: Center(
            child: Text(
              label,
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

  static const _codeLength = 6;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final codeController = useTextEditingController();
    final codeFocusNode = useFocusNode();
    final isSubmitting = useState(false);

    useListenable(codeController);

    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          codeFocusNode.requestFocus();
        }
      });
      return null;
    }, [codeFocusNode]);

    final isCodeComplete = codeController.text.length == _codeLength;

    String mapBindError(String code) {
      switch (code.trim()) {
        case "device_already_bound":
          return "Устройство уже привязано, загружаем текущий профиль...";
        case "bind_link_not_found":
          return "Ссылка профиля не найдена. Повторите позже.";
        case "bind_not_configured":
          return "Сервис привязки временно недоступен.";
        case "network_connectionTimeout":
          return "Сервер долго отвечает. Проверьте интернет и повторите.";
        case "network_connectionError":
          return "Нет соединения с сервером.";
        default:
          return code.isEmpty ? t.errors.unexpected : code;
      }
    }

    void showError(String message) {
      final notification = ref.read(inAppNotificationControllerProvider);
      notification.showErrorToast(message);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.red.shade700));
    }

    Future<void> bind() async {
      if (isSubmitting.value) return;

      final code = codeController.text.trim();

      if (!RegExp(r'^\d{6}$').hasMatch(code)) {
        showError(t.errors.unexpected);
        return;
      }

      isSubmitting.value = true;
      try {
        await ref.read(mobileBindServiceProvider).confirmCode(code).timeout(const Duration(seconds: 30));
      } on MobileBindException catch (e) {
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
              t.pages.profileDetails.linkAccount.description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: helperTextColor,
                fontFamily: 'Montserrat',
                fontWeight: FontWeight.w500,
              ),
            ),
            const Gap(16),
            Text(
              t.pages.profileDetails.linkAccount.codeLabel,
              style: theme.textTheme.labelLarge?.copyWith(fontFamily: 'Montserrat', fontWeight: FontWeight.w600),
            ),
            const Gap(10),
            SizedBox(
              width: double.infinity,
              child: TextField(
                controller: codeController,
                focusNode: codeFocusNode,
                onSubmitted: (_) => bind(),
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontFamily: 'Montserrat',
                  fontWeight: FontWeight.w700,
                  letterSpacing: 10,
                  color: titleColor,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(_codeLength),
                ],
                decoration: InputDecoration(
                  hintText: '000000',
                  hintStyle: theme.textTheme.headlineSmall?.copyWith(
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w700,
                    letterSpacing: 10,
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
            onPressed: isSubmitting.value || !isCodeComplete ? null : bind,
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
    final lineOneTwoStyle = theme.textTheme.titleLarge?.copyWith(
      fontFamily: "Unbounded",
      fontWeight: FontWeight.w300,
      fontSize: 32,
      height: 27 / 32,
    );
    final lineThreeStyle = theme.textTheme.titleLarge?.copyWith(
      fontFamily: "Unbounded",
      fontWeight: FontWeight.w700,
      fontSize: 32,
      height: 37 / 32,
    );
    final maxLineWidth = switch (activeBreakpoint) {
      Breakpoints.mobile => 260.0,
      Breakpoints.tablet => 460.0,
      Breakpoints.desktop => 520.0,
    };
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 20),
      child: SizedBox(
        width: maxLineWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(line1, maxLines: 1, overflow: TextOverflow.ellipsis, style: lineOneTwoStyle),
            Text(line2, maxLines: 1, overflow: TextOverflow.ellipsis, style: lineOneTwoStyle),
            Text(line3, maxLines: 2, overflow: TextOverflow.ellipsis, style: lineThreeStyle),
          ],
        ),
      ),
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

class RegionLocale {
  final Region region;
  final AppLocale locale;

  RegionLocale(this.region, this.locale);
}

class RegionDetector {
  /// Returns: 'IR' | 'AF' | 'CN' | 'TR' | 'RU' | 'BR' | 'US'
  static String detect() {
    final now = DateTime.now();
    final offset = now.timeZoneOffset.inMinutes;
    final tz = now.timeZoneName.toLowerCase().trim();

    if (offset == 210) return 'IR';

    if (offset == 270) {
      final (_, country) = _parseLocale();
      return country == 'IR' ? 'IR' : 'AF';
    }

    final fromName = _fromTzName(tz, offset);
    if (fromName != null) return fromName;

    final candidates = _candidatesForOffset(offset);
    if (candidates.isEmpty) return 'US';

    return _resolveByLocale(candidates);
  }

  static String? _fromTzName(String tz, int offset) {
    if (tz.contains('/')) {
      final city = tz.split('/').last.replaceAll(' ', '_');
      final r = _ianaCities[city];
      if (r != null) return r;
    }

    if (tz == 'irst' || tz == 'irdt' || tz.contains('iran')) return 'IR';

    if (tz == 'aft' || tz.contains('afghanistan')) return 'AF';

    if (tz == 'trt' || tz.contains('turkey') || tz.contains('istanbul')) {
      return 'TR';
    }

    if (tz.contains('china') || tz.contains('beijing')) return 'CN';
    if (tz == 'cst' && offset == 480) return 'CN';

    if (_matchesRussiaTz(tz)) return 'RU';

    if (_matchesBrazilTz(tz)) return 'BR';

    return null;
  }

  static bool _matchesRussiaTz(String tz) {
    if (tz.contains('russia') || tz.contains('moscow')) return true;

    const abbrs = {'msk', 'yekt', 'omst', 'krat', 'irkt', 'yakt', 'vlat', 'magt', 'pett', 'sakt', 'sret'};
    if (abbrs.contains(tz)) return true;

    const winKeys = [
      'ekaterinburg',
      'kaliningrad',
      'yakutsk',
      'vladivostok',
      'magadan',
      'sakhalin',
      'kamchatka',
      'astrakhan',
      'saratov',
      'volgograd',
      'altai',
      'tomsk',
      'transbaikal',
      'n. central asia',
      'north asia',
    ];
    return winKeys.any(tz.contains);
  }

  static bool _matchesBrazilTz(String tz) {
    if (tz == 'brt' || tz == 'brst') return true;
    if (tz.contains('brazil') || tz.contains('brasilia')) return true;

    const winKeys = ['e. south america', 'central brazilian', 'tocantins', 'bahia'];
    return winKeys.any(tz.contains);
  }

  static Set<String> _candidatesForOffset(int offset) {
    final c = <String>{};

    if (offset == 180) c.add('TR');

    if (offset == 480) c.add('CN');

    if (_ruOffsets.contains(offset)) c.add('RU');

    if (_brOffsets.contains(offset)) c.add('BR');

    return c;
  }

  static const _ruOffsets = {120, 180, 240, 300, 360, 420, 480, 540, 600, 660, 720};

  static const _brOffsets = {-120, -180, -240, -300};

  static String _resolveByLocale(Set<String> candidates) {
    final (lang, country) = _parseLocale();

    if (country != null && candidates.contains(country)) {
      return country;
    }

    final regionFromLang = _langToRegion[lang];
    if (regionFromLang != null && candidates.contains(regionFromLang)) {
      return regionFromLang;
    }

    return 'US';
  }

  static (String, String?) _parseLocale() {
    try {
      final parts = Platform.localeName.split(RegExp(r'[_\-.]'));
      final lang = parts.first.toLowerCase();

      String? country;
      for (final p in parts.skip(1)) {
        if (p.length == 2) {
          country = p.toUpperCase();
          break;
        }
      }

      return (lang, country);
    } catch (_) {
      return ('en', null);
    }
  }

  static const _langToRegion = <String, String>{'fa': 'IR', 'ps': 'AF', 'tr': 'TR', 'zh': 'CN', 'ru': 'RU', 'pt': 'BR'};

  static const _ianaCities = <String, String>{
    'tehran': 'IR',
    'kabul': 'AF',
    'istanbul': 'TR',
    'shanghai': 'CN',
    'chongqing': 'CN',
    'urumqi': 'CN',
    'harbin': 'CN',
    'moscow': 'RU',
    'kaliningrad': 'RU',
    'samara': 'RU',
    'yekaterinburg': 'RU',
    'omsk': 'RU',
    'novosibirsk': 'RU',
    'barnaul': 'RU',
    'tomsk': 'RU',
    'krasnoyarsk': 'RU',
    'irkutsk': 'RU',
    'chita': 'RU',
    'yakutsk': 'RU',
    'vladivostok': 'RU',
    'magadan': 'RU',
    'sakhalin': 'RU',
    'kamchatka': 'RU',
    'anadyr': 'RU',
    'volgograd': 'RU',
    'saratov': 'RU',
    'astrakhan': 'RU',
    'sao_paulo': 'BR',
    'fortaleza': 'BR',
    'recife': 'BR',
    'manaus': 'BR',
    'belem': 'BR',
    'cuiaba': 'BR',
    'bahia': 'BR',
    'rio_branco': 'BR',
    'noronha': 'BR',
    'porto_velho': 'BR',
    'campo_grande': 'BR',
  };
}
