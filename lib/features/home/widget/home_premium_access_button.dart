import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/features/home/widget/home_premium_access_view.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/profile/overview/external_subscription_account.dart';

const _debugSeedProfileEnabled = bool.fromEnvironment("debug_seed_profile_enabled");
const _debugSeedProfileRemainingDays = int.fromEnvironment("debug_seed_profile_remaining_days", defaultValue: -1);

class HomePremiumAccessButton extends ConsumerWidget {
  const HomePremiumAccessButton({super.key, this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16)});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;

    final profile = switch (ref.watch(activeProfileProvider)) {
      AsyncData(value: final profile?) => profile,
      _ => null,
    };
    final subInfo = switch (profile) {
      RemoteProfileEntity(:final subInfo) => subInfo,
      _ => null,
    };

    final rawRemainingDays = _resolveRemainingDays(subInfo);
    return Padding(
      padding: padding,
      child: HomePremiumAccessView(
        remainingDays: rawRemainingDays,
        label: rawRemainingDays != null && rawRemainingDays >= 1
            ? _buildPremiumLabel(context, t, rawRemainingDays)
            : '',
        title: t.pages.profileDetails.specialServers.headerLineOne,
        subtitle: _localizedInternetEverywhere(context),
        onPressed: () =>
            unawaited(openExternalSubscriptionAccount(context, ref, profile is RemoteProfileEntity ? profile : null)),
      ),
    );
  }
}

int? _resolveRemainingDays(SubscriptionInfo? subInfo) {
  if (_debugSeedProfileEnabled && _debugSeedProfileRemainingDays != -1) {
    return _debugSeedProfileRemainingDays;
  }
  if (subInfo == null) return null;
  final remaining = subInfo.remaining;
  if (remaining.inSeconds <= 0) return 0;
  final days = remaining.inDays;
  return days < 1 ? 1 : days;
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
