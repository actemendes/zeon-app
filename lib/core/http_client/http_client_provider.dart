import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:zeon/core/app_info/app_info_provider.dart';
import 'package:zeon/core/http_client/api_vpn_recovery.dart';
import 'package:zeon/core/http_client/dio_http_client.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';

part 'http_client_provider.g.dart';

@Riverpod(keepAlive: true)
DioHttpClient httpClient(Ref ref) {
  final client = DioHttpClient(
    timeout: const Duration(seconds: 15),
    userAgent: ref.watch(appInfoProvider).requireValue.userAgent,
    debug: kDebugMode,
    requestVpnRecovery: () => ref.read(apiVpnRecoveryProvider).recover(),
  );

  ref.listen(ConfigOptions.mixedPort, (_, next) => client.setProxyPort(next), fireImmediately: true);
  return client;
}
