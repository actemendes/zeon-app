import 'package:dartx/dartx.dart';
import 'package:flutter/foundation.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';

abstract class GithubReleaseParser {
  static const _androidExpectedAsset = "zeon-android-universal.apk";
  static const _windowsExpectedAsset = "zeon-windows-setup-x64.exe";
  static const _macExpectedAsset = "zeon-macos.dmg";

  static final _androidAssetPattern = RegExp(r'(?:zeon[-_.]?)?android.*\.apk$', caseSensitive: false);
  static final _windowsExePattern = RegExp(
    r'(?:zeon[-_.]?)?windows.*(?:setup|installer)?.*\.exe$',
    caseSensitive: false,
  );
  static final _windowsMsiPattern = RegExp(r'windows.*\.msi$', caseSensitive: false);
  static final _windowsZipPattern = RegExp(r'windows.*\.zip$', caseSensitive: false);
  static final _macDmgPattern = RegExp(r'(?:zeon[-_.]?)?mac(?:os)?.*\.dmg$', caseSensitive: false);
  static final _macPkgPattern = RegExp(r'mac(?:os)?.*\.pkg$', caseSensitive: false);
  static final _macZipPattern = RegExp(r'mac(?:os)?.*\.zip$', caseSensitive: false);

  static RemoteVersionEntity parse(Map<String, dynamic> json) {
    final fullTag = json['tag_name'] as String;
    final fullVersion = fullTag.removePrefix("v").split("-").first.split("+");
    var version = fullVersion.first;
    var buildNumber = fullVersion.elementAtOrElse(1, (index) => "");
    var flavor = Environment.prod;
    for (final env in Environment.values) {
      final suffix = ".${env.name}";
      if (version.endsWith(suffix)) {
        version = version.removeSuffix(suffix);
        flavor = env;
        break;
      } else if (buildNumber.endsWith(suffix)) {
        buildNumber = buildNumber.removeSuffix(suffix);
        flavor = env;
        break;
      }
    }
    final preRelease = json["prerelease"] as bool;
    final publishedAt = DateTime.parse(json["published_at"] as String);
    return RemoteVersionEntity(
      version: version,
      buildNumber: buildNumber,
      releaseTag: fullTag,
      preRelease: preRelease,
      url: _resolveReleaseUrl(json),
      publishedAt: publishedAt,
      flavor: flavor,
    );
  }

  static String _resolveReleaseUrl(Map<String, dynamic> json) {
    final fallbackUrl = json["html_url"] as String;
    final rawAssets = json["assets"];
    if (rawAssets is! List) {
      return fallbackUrl;
    }
    final assets = rawAssets.map(_GithubReleaseAsset.tryParse).whereType<_GithubReleaseAsset>().toList();
    if (assets.isEmpty) {
      return fallbackUrl;
    }
    final platformAsset = switch (_currentAssetPlatform()) {
      _ReleaseAssetPlatform.android => _pickAndroidAsset(assets),
      _ReleaseAssetPlatform.windows => _pickWindowsAsset(assets),
      _ReleaseAssetPlatform.macos => _pickMacAsset(assets),
      _ReleaseAssetPlatform.other => null,
    };
    return platformAsset?.downloadUrl ?? fallbackUrl;
  }

  static _ReleaseAssetPlatform _currentAssetPlatform() {
    if (kIsWeb) {
      return _ReleaseAssetPlatform.other;
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => _ReleaseAssetPlatform.android,
      TargetPlatform.windows => _ReleaseAssetPlatform.windows,
      TargetPlatform.macOS => _ReleaseAssetPlatform.macos,
      _ => _ReleaseAssetPlatform.other,
    };
  }

  static _GithubReleaseAsset? _pickAndroidAsset(List<_GithubReleaseAsset> assets) => _pickFirstMatch(assets, [
    (asset) => asset.normalizedName == _androidExpectedAsset,
    (asset) => _androidAssetPattern.hasMatch(asset.name),
    (asset) => asset.normalizedName.contains("android") && asset.normalizedName.endsWith(".apk"),
    (asset) => asset.normalizedName.endsWith(".apk"),
  ]);

  static _GithubReleaseAsset? _pickWindowsAsset(List<_GithubReleaseAsset> assets) => _pickFirstMatch(assets, [
    (asset) => asset.normalizedName == _windowsExpectedAsset,
    (asset) => _windowsExePattern.hasMatch(asset.name),
    (asset) => asset.normalizedName.endsWith(".exe"),
    (asset) => _windowsMsiPattern.hasMatch(asset.name),
    (asset) => asset.normalizedName.endsWith(".msi"),
    (asset) => _windowsZipPattern.hasMatch(asset.name),
    (asset) => asset.normalizedName.contains("windows") && asset.normalizedName.endsWith(".zip"),
    (asset) => asset.normalizedName.endsWith(".zip"),
  ]);

  static _GithubReleaseAsset? _pickMacAsset(List<_GithubReleaseAsset> assets) => _pickFirstMatch(assets, [
    (asset) => asset.normalizedName == _macExpectedAsset,
    (asset) => _macDmgPattern.hasMatch(asset.name),
    (asset) => asset.normalizedName.contains("mac") && asset.normalizedName.endsWith(".dmg"),
    (asset) => asset.normalizedName.endsWith(".dmg"),
    (asset) => _macPkgPattern.hasMatch(asset.name),
    (asset) => asset.normalizedName.endsWith(".pkg"),
    (asset) => _macZipPattern.hasMatch(asset.name),
    (asset) => asset.normalizedName.contains("mac") && asset.normalizedName.endsWith(".zip"),
    (asset) => asset.normalizedName.endsWith(".zip"),
  ]);

  static _GithubReleaseAsset? _pickFirstMatch(
    List<_GithubReleaseAsset> assets,
    List<bool Function(_GithubReleaseAsset)> checks,
  ) {
    for (final check in checks) {
      final match = assets.firstOrNullWhere(check);
      if (match != null) {
        return match;
      }
    }
    return null;
  }
}

enum _ReleaseAssetPlatform { android, windows, macos, other }

class _GithubReleaseAsset {
  const _GithubReleaseAsset({required this.name, required this.downloadUrl});

  final String name;
  final String downloadUrl;

  String get normalizedName => name.toLowerCase();

  static _GithubReleaseAsset? tryParse(dynamic raw) {
    if (raw is! Map) {
      return null;
    }
    final name = raw["name"];
    final downloadUrl = raw["browser_download_url"];
    if (name is! String || downloadUrl is! String || downloadUrl.isEmpty) {
      return null;
    }
    return _GithubReleaseAsset(name: name, downloadUrl: downloadUrl);
  }
}
