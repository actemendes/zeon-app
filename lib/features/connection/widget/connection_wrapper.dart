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
    ref.listen(connectionNotifierProvider, (_, next) => _syncHttpVpnState(next));

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
      _syncHttpVpnState(ref.read(connectionNotifierProvider));
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
      ref.read(httpClientProvider).setVpnActive(status is! Disconnected);
    } else if (next.hasError) {
      ref.read(httpClientProvider).setVpnActive(false);
    }
  }
}
