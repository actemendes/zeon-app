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
        label: rawRemainingDays != null && rawRemainingDays >= 1 ? _buildPremiumLabel(t, rawRemainingDays) : '',
        title: t.pages.profileDetails.specialServers.headerLineOne,
        subtitle: t.pages.home.internetEverywhere,
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

String _buildPremiumLabel(Translations t, int days) {
  return days > 10 ? t.pages.home.youArePremium : t.pages.home.premiumDaysRemaining(n: days);
}
