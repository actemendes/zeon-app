import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _debugSeedProfileEnabled = bool.fromEnvironment("debug_seed_profile_enabled");
const _debugSeedProfileRemainingDays = int.fromEnvironment("debug_seed_profile_remaining_days", defaultValue: -1);

class HomePremiumAccessButton extends ConsumerWidget {
  const HomePremiumAccessButton({super.key});

  static const _activeBackgroundPrefix = 'assets/images/1x/count-days-';
  static const _activeBackgroundMaxDay = 10;
  static const _inactiveBackgroundAsset = 'assets/images/1x/cta-background.png';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    final profile = switch (ref.watch(activeProfileProvider)) {
      AsyncData(value: final profile?) => profile,
      _ => null,
    };
    final subInfo = switch (profile) {
      RemoteProfileEntity(:final subInfo) => subInfo,
      _ => null,
    };

    final rawRemainingDays = _resolveRemainingDays(subInfo);
    final isPremiumActive = rawRemainingDays != null && rawRemainingDays >= 1;
    final iconAndTextColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : const Color(0xFF3B444D);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: isPremiumActive
          ? _ActivePremiumState(
              textColor: iconAndTextColor,
              backgroundAsset: '$_activeBackgroundPrefix${rawRemainingDays.clamp(0, _activeBackgroundMaxDay)}.png',
              onPressed: () => context.pushNamed('profilePayment'),
              label: _buildPremiumLabel(context, t, rawRemainingDays),
            )
          : _InactivePremiumState(
              title: t.pages.profileDetails.specialServers.headerLineOne,
              subtitle: _localizedInternetEverywhere(context),
              textColor: iconAndTextColor,
              backgroundAsset: _inactiveBackgroundAsset,
              onPressed: () => context.pushNamed('profilePayment'),
            ),
    );
  }
}

class _InactivePremiumState extends StatelessWidget {
  const _InactivePremiumState({
    required this.title,
    required this.subtitle,
    required this.textColor,
    required this.backgroundAsset,
    required this.onPressed,
  });

  static const double _height = 65;
  static const double _leftSegmentWidth = 65;
  static const double _crownPadding = 18;
  static const double _crownSize = 29;
  static const double _arrowSize = 24;
  static const double _arrowVisualScale = 1.18;

  final String title;
  final String subtitle;
  final Color textColor;
  final String backgroundAsset;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        height: _height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          image: DecorationImage(image: AssetImage(backgroundAsset), fit: BoxFit.cover),
        ),
        child: InkWell(
          onTap: onPressed,
          child: Row(
            children: [
              Container(
                width: _leftSegmentWidth,
                height: _height,
                color: Colors.transparent,
                padding: const EdgeInsets.all(_crownPadding),
                child: _PremiumCrownIcon(size: _crownSize, color: textColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontFamily: 'Unbounded',
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                        color: textColor,
                        height: 1,
                      ),
                    ),
                    const Gap(7),
                    Text(
                      subtitle.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'Montserrat',
                        fontWeight: FontWeight.w500,
                        fontSize: 14,
                        color: textColor,
                        height: 1,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox.square(
                dimension: 44,
                child: Center(
                  child: Transform.scale(
                    scale: _arrowVisualScale,
                    child: Icon(Icons.arrow_outward, size: _arrowSize, color: textColor),
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

class _ActivePremiumState extends StatelessWidget {
  const _ActivePremiumState({
    required this.textColor,
    required this.backgroundAsset,
    required this.onPressed,
    required this.label,
  });

  static const _height = 35.19;

  final Color textColor;
  final String backgroundAsset;
  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        height: _height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          image: DecorationImage(image: AssetImage(backgroundAsset), fit: BoxFit.cover),
        ),
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                label.toUpperCase(),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFamily: 'Unbounded',
                  fontWeight: FontWeight.w500,
                  fontSize: 18,
                  height: 1,
                  color: textColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PremiumCrownIcon extends StatelessWidget {
  const _PremiumCrownIcon({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _PremiumCrownPainter(color)),
    );
  }
}

class _PremiumCrownPainter extends CustomPainter {
  const _PremiumCrownPainter(this.color);

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
  bool shouldRepaint(covariant _PremiumCrownPainter oldDelegate) => oldDelegate.color != color;
}

int? _resolveRemainingDays(SubscriptionInfo? subInfo) {
  if (_debugSeedProfileEnabled && _debugSeedProfileRemainingDays != -1) {
    return _debugSeedProfileRemainingDays;
  }
  return subInfo?.remaining.inDays;
}

String _buildPremiumLabel(BuildContext context, Translations t, int days) {
  if (days > 10) {
    return _localizedYouArePremium(context);
  }
  final languageCode = Localizations.localeOf(context).languageCode.toLowerCase();
  if (languageCode == 'ru') {
    return '${_russianRemainingVerb(days)} $days ${_russianDayWord(days)}';
  }
  return t.components.subscriptionInfo.remainingDuration(duration: days);
}

String _russianRemainingVerb(int count) {
  return _isRussianSingleDay(count) ? 'Остался' : 'Осталось';
}

String _russianDayWord(int count) {
  final normalized = count.abs() % 100;
  final lastDigit = normalized % 10;
  if (normalized >= 11 && normalized <= 14) {
    return 'дней';
  }
  if (lastDigit == 1) {
    return 'день';
  }
  if (lastDigit >= 2 && lastDigit <= 4) {
    return 'дня';
  }
  return 'дней';
}

bool _isRussianSingleDay(int count) {
  final normalized = count.abs() % 100;
  return normalized % 10 == 1 && normalized != 11;
}

String _localizedInternetEverywhere(BuildContext context) {
  final locale = Localizations.localeOf(context);
  final lang = locale.languageCode.toLowerCase();
  final country = (locale.countryCode ?? '').toUpperCase();

  switch (lang) {
    case 'ru':
      return 'Интернет везде';
    case 'es':
      return 'Internet en todas partes';
    case 'fa':
      return 'اینترنت همه‌جا';
    case 'fr':
      return 'Internet partout';
    case 'id':
      return 'Internet di mana saja';
    case 'pt':
      return country == 'BR' ? 'Internet em todo lugar' : 'Internet em toda parte';
    case 'tr':
      return 'İnternet her yerde';
    case 'zh':
      return country == 'TW' ? '網路無所不在' : '网络无处不在';
    case 'ar':
      return 'الإنترنت في كل مكان';
    case 'en':
    default:
      return 'Internet everywhere';
  }
}

String _localizedYouArePremium(BuildContext context) {
  final locale = Localizations.localeOf(context);
  final lang = locale.languageCode.toLowerCase();
  final country = (locale.countryCode ?? '').toUpperCase();

  switch (lang) {
    case 'ru':
      return 'Вы премиум';
    case 'es':
      return 'Eres premium';
    case 'fa':
      return 'شما پریمیوم هستید';
    case 'fr':
      return 'Vous etes premium';
    case 'id':
      return 'Anda premium';
    case 'pt':
      return country == 'BR' ? 'Voce e premium' : 'Voce e premium';
    case 'tr':
      return 'Premium uyesisiniz';
    case 'zh':
      return country == 'TW' ? '您是高級會員' : '您是高级会员';
    case 'ar':
      return 'أنت بريميوم';
    case 'en':
    default:
      return 'You are premium';
  }
}
