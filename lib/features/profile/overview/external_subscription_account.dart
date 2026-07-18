import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/features/mobile/data/external_subscription_sync_service.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/utils/utils.dart';

Future<void> openExternalSubscriptionAccount(BuildContext context, WidgetRef ref, RemoteProfileEntity? profile) async {
  final opened = await ref.read(externalSubscriptionSyncServiceProvider).openExternalAccount(profile);
  if (opened || !context.mounted) return;

  final t = ref.read(translationsProvider).requireValue;
  CustomToast.error(t.pages.profileDetails.specialServers.paymentLaunchError).show(context);
}
