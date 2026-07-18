import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/notification/in_app_notification_controller.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/profile/data/profile_data_providers.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/utils/utils.dart';

final externalSubscriptionSyncServiceProvider = Provider<ExternalSubscriptionSyncService>((ref) {
  return ExternalSubscriptionSyncService(ref, ref.read(sharedPreferencesProvider).requireValue);
});

enum ExternalSubscriptionSyncResult { changed, unchanged, failed, skipped }

class ExternalSubscriptionSyncService with InfraLogger {
  ExternalSubscriptionSyncService(this.ref, this._preferences);

  static const _pendingExternalAccountOpenKey = 'external_subscription_account_opened_at_ms';
  static const _pendingLifetime = Duration(hours: 24);

  final Ref ref;
  final SharedPreferences _preferences;

  bool get hasPendingExternalAccountReturn {
    final openedAtMs = _preferences.getInt(_pendingExternalAccountOpenKey);
    if (openedAtMs == null) return false;
    final openedAt = DateTime.fromMillisecondsSinceEpoch(openedAtMs);
    return DateTime.now().difference(openedAt) <= _pendingLifetime;
  }

  Future<bool> openExternalAccount(RemoteProfileEntity? profile) async {
    final uri = buildExternalSubscriptionAccountUri(profileUrl: profile?.url, webPageUrl: profile?.subInfo?.webPageUrl);
    if (uri == null) {
      loggy.warning('external subscription account launch skipped [reason=missing_open_profile_url]');
      return false;
    }

    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      loggy.warning('external subscription account launch failed [host=${uri.host}]');
      return false;
    }

    await _preferences.setInt(_pendingExternalAccountOpenKey, DateTime.now().millisecondsSinceEpoch);
    loggy.info('external subscription account opened [host=${uri.host}]');
    return true;
  }

  Future<ExternalSubscriptionSyncResult> refreshPendingSubscription() async {
    if (!hasPendingExternalAccountReturn) {
      await finishPendingCheck();
      return ExternalSubscriptionSyncResult.skipped;
    }

    final active = await ref.read(activeProfileProvider.future);
    if (active is! RemoteProfileEntity) {
      loggy.warning('external subscription refresh skipped [reason=active_profile_is_not_remote]');
      await finishPendingCheck();
      return ExternalSubscriptionSyncResult.skipped;
    }

    final previousExpiry = active.subInfo?.expire;
    final proxyOnly = ref.read(connectionNotifierProvider).valueOrNull?.isConnected ?? false;
    final repository = ref.read(profileRepositoryProvider).requireValue;
    final updateResult = await repository.upsertRemote(active.url, proxyOnly: proxyOnly).run();
    if (updateResult.isLeft()) {
      loggy.warning('external subscription refresh failed [profile_id=${active.id}]');
      return ExternalSubscriptionSyncResult.failed;
    }

    final updatedResult = await repository.getById(active.id).run();
    final updated = updatedResult.getOrElse((_) => null);
    if (updated is! RemoteProfileEntity) {
      loggy.warning('external subscription refresh failed [reason=updated_profile_not_found profile_id=${active.id}]');
      return ExternalSubscriptionSyncResult.failed;
    }

    final currentExpiry = updated.subInfo?.expire;
    final changed = previousExpiry?.millisecondsSinceEpoch != currentExpiry?.millisecondsSinceEpoch;
    if (!changed) {
      loggy.info('external subscription refresh completed without changes [profile_id=${active.id}]');
      return ExternalSubscriptionSyncResult.unchanged;
    }

    await finishPendingCheck();
    await ref.read(connectionNotifierProvider.notifier).reconnect(updated);
    final t = ref.read(translationsProvider).valueOrNull;
    ref
        .read(inAppNotificationControllerProvider)
        .showSuccessToast(t?.pages.profiles.msg.update.success ?? 'Subscription updated');
    loggy.info(
      'external subscription change applied '
      '[profile_id=${active.id} previous_expiry=$previousExpiry current_expiry=$currentExpiry]',
    );
    return ExternalSubscriptionSyncResult.changed;
  }

  Future<void> finishPendingCheck() async {
    await _preferences.remove(_pendingExternalAccountOpenKey);
  }
}

Uri? buildExternalSubscriptionAccountUri({String? profileUrl, String? webPageUrl}) {
  for (final candidate in [webPageUrl, profileUrl]) {
    final raw = candidate?.trim();
    if (raw == null || raw.isEmpty) continue;
    final publicUrl = LinkParser.toPublicOpenProfileLink(raw);
    final uri = Uri.tryParse(publicUrl);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) continue;
    if (uri.pathSegments.length < 2 || uri.pathSegments.first.toLowerCase() != 'open') continue;
    return uri.replace(fragment: 'profile');
  }
  return null;
}
