import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:zeon/core/model/app_info_entity.dart';
import 'package:zeon/core/model/environment.dart';
import 'package:zeon/utils/platform_utils.dart';

part 'app_info_provider.g.dart';

@Riverpod(keepAlive: true)
Environment environment(Ref ref) => throw Exception("override environmentProvider");

@Riverpod(keepAlive: true)
class AppInfo extends _$AppInfo {
  static const _definedVersion = String.fromEnvironment('app_version');
  static const _definedBuildNumber = String.fromEnvironment('app_build_number');

  @override
  Future<AppInfoEntity> build() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final environment = ref.watch(environmentProvider);
    return AppInfoEntity(
      name: packageInfo.appName,
      version: _resolvePackageValue(packageInfo.version, _definedVersion),
      buildNumber: _resolvePackageValue(packageInfo.buildNumber, _definedBuildNumber),
      release: Release.read(),
      operatingSystem: PlatformUtils.operatingSystem,
      operatingSystemVersion: PlatformUtils.operatingSystemVersion,
      environment: environment,
    );
  }

  String _resolvePackageValue(String packageValue, String definedValue) {
    final value = packageValue.trim();
    if (_isUsablePackageValue(value)) return value;
    final fallback = definedValue.trim();
    return fallback.isNotEmpty ? fallback : value;
  }

  bool _isUsablePackageValue(String value) {
    if (value.isEmpty) return false;
    final lower = value.toLowerCase();
    if (lower == '<redacted>' || lower == 'redacted') return false;
    return !(value.startsWith(r'$(') && value.endsWith(')'));
  }
}
