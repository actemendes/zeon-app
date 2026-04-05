// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/app_info_entity.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/home/widget/home_page.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/settings/notifier/config_option/config_option_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/widgetbook/widgetbook_context.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:widgetbook_annotation/widgetbook_annotation.dart' as widgetbook;

@widgetbook.UseCase(name: 'Disconnected', type: HomePage, path: '[Screens]/Home')
Widget homePageDisconnectedUseCase(BuildContext context) {
  return _HomePagePreview(
    overrides: [
      connectionNotifierProvider.overrideWith(_MockDisconnectedConnectionNotifier.new),
      activeProxyNotifierProvider.overrideWith(_MockIdleActiveProxyNotifier.new),
    ],
  );
}

@widgetbook.UseCase(name: 'Connected', type: HomePage, path: '[Screens]/Home')
Widget homePageConnectedUseCase(BuildContext context) {
  return _HomePagePreview(
    overrides: [
      connectionNotifierProvider.overrideWith(_MockConnectedConnectionNotifier.new),
      activeProxyNotifierProvider.overrideWith(_MockFastActiveProxyNotifier.new),
    ],
  );
}

class _HomePagePreview extends StatelessWidget {
  const _HomePagePreview({required this.overrides});

  final List<Override> overrides;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) => widgetbookSharedPreferences),
        translationsProvider.overrideWith((ref) => TranslationsEn()),
        appInfoProvider.overrideWith(_MockAppInfoNotifier.new),
        activeProfileProvider.overrideWith(_MockActiveProfileNotifier.new),
        configOptionNotifierProvider.overrideWith(_MockConfigOptionNotifier.new),
        ...overrides,
      ],
      child: const HomePage(),
    );
  }
}

class _MockAppInfoNotifier extends AppInfo {
  @override
  Future<AppInfoEntity> build() async {
    return const AppInfoEntity(
      name: 'Hiddify',
      version: '4.1.2',
      buildNumber: '40102',
      release: Release.general,
      operatingSystem: 'widgetbook',
      operatingSystemVersion: 'web',
      environment: Environment.dev,
    );
  }
}

class _MockActiveProfileNotifier extends ActiveProfile {
  @override
  Stream<ProfileEntity?> build() {
    return Stream.value(null);
  }
}

class _MockDisconnectedConnectionNotifier extends ConnectionNotifier {
  @override
  Stream<ConnectionStatus> build() {
    return Stream.value(const Disconnected());
  }

  @override
  Future<void> toggleConnection() async {}

  @override
  Future<void> reconnect(ProfileEntity? profile) async {}
}

class _MockConnectedConnectionNotifier extends ConnectionNotifier {
  @override
  Stream<ConnectionStatus> build() {
    return Stream.value(const Connected());
  }

  @override
  Future<void> toggleConnection() async {}

  @override
  Future<void> reconnect(ProfileEntity? profile) async {}
}

class _MockIdleActiveProxyNotifier extends ActiveProxyNotifier {
  @override
  Stream<OutboundInfo> build() {
    return Stream.value(
      OutboundInfo(
        tagDisplay: 'Preview Proxy',
        type: 'VMess',
        ipinfo: IpInfo(ip: '', countryCode: 'US', org: 'Widgetbook'),
        urlTestDelay: 0,
      ),
    );
  }

  @override
  Future<void> urlTest(String? groupTag_) async {}
}

class _MockFastActiveProxyNotifier extends ActiveProxyNotifier {
  @override
  Stream<OutboundInfo> build() {
    return Stream.value(
      OutboundInfo(
        tagDisplay: 'US Fast',
        type: 'Reality',
        ipinfo: IpInfo(ip: '104.26.2.33', countryCode: 'US', org: 'Cloudflare'),
        urlTestDelay: 42,
      ),
    );
  }

  @override
  Future<void> urlTest(String? groupTag_) async {}
}

class _MockConfigOptionNotifier extends ConfigOptionNotifier {
  @override
  Future<bool> build() async {
    return false;
  }
}
