import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/device/android_tv_provider.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/dialog/widgets/zeon_dialog.dart';
import 'package:zeon/features/mobile/data/external_subscription_sync_service.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/overview/tv_subscription_payment_dialog.dart';
import 'package:zeon/utils/utils.dart';

Future<void> openExternalSubscriptionAccount(BuildContext context, WidgetRef ref, RemoteProfileEntity? profile) async {
  final isTv = await ref.read(androidTvProvider.future);
  if (!context.mounted) return;
  if (isTv) {
    final uri = buildExternalSubscriptionAccountUri(profileUrl: profile?.url, webPageUrl: profile?.subInfo?.webPageUrl);
    if (uri != null && profile != null) {
      final service = ref.read(externalSubscriptionSyncServiceProvider);
      await showZeonDialog<void>(
        context,
        TvSubscriptionPaymentDialog(
          uri: uri,
          refresh: () => service.refreshSubscription(expectedProfileId: profile.id),
        ),
      );
      return;
    }
    final t = ref.read(translationsProvider).requireValue;
    CustomToast.error(t.pages.profileDetails.specialServers.paymentLaunchError).show(context);
    return;
  }
  final opened = await ref.read(externalSubscriptionSyncServiceProvider).openExternalAccount(profile);
  if (opened || !context.mounted) return;

  final t = ref.read(translationsProvider).requireValue;
  CustomToast.error(t.pages.profileDetails.specialServers.paymentLaunchError).show(context);
}
