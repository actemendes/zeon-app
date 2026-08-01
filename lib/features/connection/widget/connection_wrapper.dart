import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/http_client/http_client_provider.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/notification/in_app_notification_controller.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/mobile/data/mobile_bootstrap_import_service.dart';
import 'package:zeon/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/route_rules/data/managed_rule_set_sync.dart';
import 'package:zeon/features/settings/notifier/config_option/config_option_notifier.dart';
import 'package:zeon/utils/custom_loggers.dart';
import 'package:zeon/utils/platform_utils.dart';

class ConnectionWrapper extends StatefulHookConsumerWidget {
  const ConnectionWrapper(this.child, {super.key});

  final Widget child;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _ConnectionWrapperState();
}

class _ConnectionWrapperState extends ConsumerState<ConnectionWrapper> with AppLogger {
  @override
  Widget build(BuildContext context) {
    ref.listen(connectionNotifierProvider, (previous, next) {
      _syncHttpVpnState(next);
      final wasConnected = previous?.asData?.value is Connected;
      final isConnected = next.asData?.value is Connected;
      if (isConnected && !wasConnected) {
        unawaited(ref.read(managedRuleSetSyncServiceProvider).syncWhenVpnAvailable());
      }
    });

    ref.listen(configOptionNotifierProvider, (previous, next) async {
      if (next case AsyncData(value: true)) {
        final t = ref.read(translationsProvider).requireValue;
        ref
            .read(inAppNotificationControllerProvider)
            .showInfoToast(
              t.connection.reconnectMsg,
              // actionText: t.connection.reconnect,
              // callback: () async {
              //   await ref
              //       .read(connectionNotifierProvider.notifier)
              //       .reconnect(await ref.read(activeProfileProvider.future));
              // },
            );
        await ref.read(connectionNotifierProvider.notifier).reconnect(await ref.read(activeProfileProvider.future));
      }
    });

    return widget.child;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final connection = ref.read(connectionNotifierProvider);
      _syncHttpVpnState(connection);
      if (connection.asData?.value is Connected) {
        unawaited(ref.read(managedRuleSetSyncServiceProvider).syncWhenVpnAvailable());
      }
      if (!PlatformUtils.isMobile) return;
      // A bootstrap request can fail before a Navigator exists. Retry once the
      // UI is ready so adaptive HTTP may offer VPN recovery to the user.
      unawaited(ref.read(mobileBootstrapImportServiceProvider).run(mode: MobileConnLinkImportMode.standard));
    });
    // remove for now...
    //
    // Future.delayed(const Duration(seconds: 2)).then(
    //   (_) async {
    //     if (ref.read(startedByUserProvider) && PlatformUtils.isDesktop) {
    //       loggy.debug("previously started by user, trying to connect");
    //       return ref.read(connectionNotifierProvider.notifier).mayConnect();
    //     }
    //   },
    // );
  }

  void _syncHttpVpnState(AsyncValue<ConnectionStatus> next) {
    final status = next.asData?.value;
    if (status != null) {
      ref.read(httpClientProvider).setVpnActive(hasStableVpnTransport(status));
    } else if (next.hasError) {
      ref.read(httpClientProvider).setVpnActive(false);
    }
  }
}

/// Whether control-plane HTTP requests may safely require the local proxy.
///
/// During connect and disconnect the previous proxy may already be gone while
/// the replacement is not ready yet. Only the terminal Connected state proves
/// that the proxy is available.
bool hasStableVpnTransport(ConnectionStatus status) => status is Connected;
