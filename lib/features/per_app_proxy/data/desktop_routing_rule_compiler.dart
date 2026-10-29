import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zeon/features/per_app_proxy/data/windows_installed_apps_service.dart';
import 'package:zeon/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:zeon/features/site_routing/model/site_routing_mode.dart';
import 'package:zeon/utils/validators.dart';

typedef CompanionExecutableFinder = List<String> Function(String executablePath);

@immutable
class CompiledRoutingOverlay {
  const CompiledRoutingOverlay({
    required this.leadingRules,
    required this.trailingRules,
  });

  final List<Map<String, dynamic>> leadingRules;
  final List<Map<String, dynamic>> trailingRules;
}

class DesktopRoutingRuleCompiler {
  const DesktopRoutingRuleCompiler({
    CompanionExecutableFinder? companionFinder,
  }) : _companionFinder = companionFinder ?? defaultCompanionExecutableFinder;

  final CompanionExecutableFinder _companionFinder;

  static const int outboundProxy = 0;
  static const int outboundDirect = 1;

  CompiledRoutingOverlay compileOverlay({
    required bool isDesktop,
    required PerAppProxyMode perAppProxyMode,
    required List<String> includeApps,
    required List<String> excludeApps,
    required SiteRoutingMode siteRoutingMode,
    required List<String> includeSites,
    required List<String> excludeSites,
  }) {
    final leading = <Map<String, dynamic>>[];
    final trailing = <Map<String, dynamic>>[];

    final excludeAppRules = isDesktop && perAppProxyMode == PerAppProxyMode.exclude
        ? compileAppRules(
            appIdentifiers: excludeApps,
            outbound: outboundDirect,
            ruleNamePrefix: 'pc-per-app-exclude',
          )
        : const <Map<String, dynamic>>[];

    final includeAppRules = isDesktop && perAppProxyMode == PerAppProxyMode.include
        ? compileAppRules(
            appIdentifiers: includeApps,
            outbound: outboundProxy,
            ruleNamePrefix: 'pc-per-app-include',
          )
        : const <Map<String, dynamic>>[];

    final excludeSiteRules = siteRoutingMode == SiteRoutingMode.exclude
        ? compileSiteRules(
            rawEntries: excludeSites,
            outbound: outboundDirect,
            ruleNamePrefix: 'site-routing-exclude',
          )
        : const <Map<String, dynamic>>[];

    final includeSiteRules = siteRoutingMode == SiteRoutingMode.include
        ? compileSiteRules(
            rawEntries: includeSites,
            outbound: outboundProxy,
            ruleNamePrefix: 'site-routing-include',
          )
        : const <Map<String, dynamic>>[];

    leading
      ..addAll(excludeAppRules)
      ..addAll(excludeSiteRules)
      ..addAll(includeSiteRules)
      ..addAll(includeAppRules);

    final needsDirectFallback =
        (isDesktop && perAppProxyMode == PerAppProxyMode.include && includeAppRules.isNotEmpty) ||
        (siteRoutingMode == SiteRoutingMode.include && includeSiteRules.isNotEmpty);

    if (needsDirectFallback) {
      trailing.add(<String, dynamic>{
        'enabled': true,
        'name': 'routing-include-fallback-direct',
        'outbound': outboundDirect,
        'port_ranges': const <String>['1:65535'],
      });
    }

    return CompiledRoutingOverlay(
      leadingRules: leading,
      trailingRules: trailing,
    );
  }

  /// Compiles selected desktop applications into separate `process_paths` and
  /// `process_names` rules.
  ///
  /// IMPORTANT: `sing-box` ANDs `ProcessPath` and `ProcessName` when both are
  /// present on the same `DefaultRule`, while entries inside `ProcessPath` or
  /// `ProcessName` are ORed. Therefore `process_paths` and `process_names`
  /// must always be emitted as separate rules.
  List<Map<String, dynamic>> compileAppRules({
    required Iterable<String> appIdentifiers,
    required int outbound,
    required String ruleNamePrefix,
  }) {
    final processPaths = <String>[];
    final processPathsLower = <String>{};
    final processNames = <String>[];
    final processNamesLower = <String>{};

    void addProcessPath(String rawPath) {
      final normalized = rawPath.trim().replaceAll('/', r'\');
      if (normalized.isEmpty) return;
      final lower = normalized.toLowerCase();
      if (processPathsLower.add(lower)) {
        processPaths.add(normalized);
      }
    }

    void addProcessNameWithVariants(String rawName) {
      final base = rawName.trim().split(RegExp(r'[\\/]')).last;
      if (base.isEmpty) return;
      final variants = <String>{
        base,
        base.toLowerCase(),
        if (base.length > 1) '${base[0].toUpperCase()}${base.substring(1).toLowerCase()}',
      };
      for (final variant in variants) {
        if ( !processNames.contains(variant)) {
          processNames.add(variant);
        }
      }
      processNamesLower.add(base.toLowerCase());
    }

    for (final rawIdentifier in appIdentifiers) {
      final trimmed = rawIdentifier.trim();
      if (trimmed.isEmpty) continue;
      if (WindowsInstalledAppsService.isIgnoredExecutable(trimmed)) continue;

      if (trimmed.contains(r'\') || trimmed.contains('/')) {
        addProcessPath(trimmed);
        final base = trimmed.split(RegExp(r'[\\/]')).last;
        addProcessNameWithVariants(base);

        for (final companion in _companionFinder(trimmed)) {
          if (WindowsInstalledAppsService.isIgnoredExecutable(companion)) continue;
          addProcessPath(companion);
          addProcessNameWithVariants(companion);
        }
      } else {
        addProcessNameWithVariants(trimmed.toLowerCase().endsWith('.exe') ? trimmed : '$trimmed.exe');
      }
    }

    return <Map<String, dynamic>>[
      if (processPaths.isNotEmpty)
        <String, dynamic>{
          'enabled': true,
          'name': '$ruleNamePrefix-paths',
          'outbound': outbound,
          'process_paths': processPaths,
        },
      if (processNames.isNotEmpty)
        <String, dynamic>{
          'enabled': true,
          'name': '$ruleNamePrefix-names',
          'outbound': outbound,
          'process_names': processNames,
        },
    ];
  }

  /// Compiles website domains and IP/CIDR entries into separate domain and IP
  /// rules so `sing-box` evaluates them with OR semantics.
  List<Map<String, dynamic>> compileSiteRules({
    required Iterable<String> rawEntries,
    required int outbound,
    required String ruleNamePrefix,
  }) {
    final domains = <String>[];
    final domainSuffixes = <String>[];
    final ipCidrs = <String>[];

    for (final raw in rawEntries) {
      final normalized = normalizeSiteOrResourceEntry(raw);
      if (normalized == null) continue;
      if (isIpOrCidrEntry(normalized)) {
        if (!ipCidrs.contains(normalized)) {
          ipCidrs.add(normalized);
        }
      } else {
        var suffix = normalized;
        if (suffix.startsWith('*.')) {
          suffix = suffix.substring(2);
        } else if (suffix.startsWith('.')) {
          suffix = suffix.substring(1);
        }
        if (suffix.isEmpty) continue;
        if (!domains.contains(suffix)) {
          domains.add(suffix);
        }
        if (!domainSuffixes.contains(suffix)) {
          domainSuffixes.add(suffix);
        }
      }
    }

    return <Map<String, dynamic>>[
      if (domains.isNotEmpty || domainSuffixes.isNotEmpty)
        <String, dynamic>{
          'enabled': true,
          'name': '$ruleNamePrefix-domains',
          'outbound': outbound,
          'domains': domains,
          'domain_suffixes': domainSuffixes,
        },
      if (ipCidrs.isNotEmpty)
        <String, dynamic>{
          'enabled': true,
          'name': '$ruleNamePrefix-ips',
          'outbound': outbound,
          'ip_cidrs': ipCidrs,
        },
    ];
  }

  static String? normalizeSiteOrResourceEntry(String input) {
    var trimmed = input.trim().toLowerCase();
    if (trimmed.isEmpty) return null;

    if (trimmed.contains('://')) {
      final uri = Uri.tryParse(trimmed);
      if (uri != null && uri.host.isNotEmpty) {
        trimmed = uri.host.toLowerCase();
      }
    } else if (trimmed.contains('/') && !isIpOrCidrEntry(trimmed)) {
      final firstSegment = trimmed.split('/').first.trim();
      if (InternetAddress.tryParse(firstSegment) != null) {
        return null;
      }
      final uri = Uri.tryParse('https://$trimmed');
      if (uri != null && uri.host.isNotEmpty) {
        trimmed = uri.host.toLowerCase();
      }
    }

    trimmed = trimmed.replaceFirst(RegExp(r'\.$'), '');
    if (trimmed.isEmpty) return null;

    if (isIpOrCidrEntry(trimmed)) {
      return trimmed;
    }
    if (isDomain(trimmed) || isDomainSuffix(trimmed) || (trimmed.startsWith('*.') && isDomain(trimmed.substring(2)))) {
      return trimmed;
    }
    return null;
  }

  static bool isIpOrCidrEntry(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;
    if (InternetAddress.tryParse(trimmed) != null) return true;
    final parts = trimmed.split('/');
    if (parts.length != 2) return false;
    final ipPart = parts[0].trim();
    final prefix = int.tryParse(parts[1].trim());
    final parsedIp = InternetAddress.tryParse(ipPart);
    if (prefix == null || parsedIp == null) return false;
    if (parsedIp.type == InternetAddressType.IPv6) {
      return prefix >= 0 && prefix <= 128;
    }
    return prefix >= 0 && prefix <= 32;
  }

  static const Set<String> _sharedDirectoryNames = <String>{
    'windows',
    'system32',
    'syswow64',
    'program files',
    'program files (x86)',
    'programdata',
    'users',
    'downloads',
    'desktop',
    'documents',
    'temp',
    'tmp',
    'local',
    'roaming',
    'appdata',
    'programs',
  };

  static List<String> defaultCompanionExecutableFinder(String executablePath) {
    final normalized = executablePath.trim().replaceAll('/', r'\');
    final file = File(normalized);
    final parent = file.parent;
    if (!parent.existsSync()) return const <String>[];

    final parentName = parent.path.split(RegExp(r'[\\/]')).last.toLowerCase();
    if (parentName.isEmpty || _sharedDirectoryNames.contains(parentName)) {
      return const <String>[];
    }

    // Check if the parent is a dedicated application folder.
    final companions = <String>[];
    void collectFrom(Directory dir, {int depth = 0}) {
      if (depth > 1 || companions.length >= 16) return;
      List<FileSystemEntity> entities;
      try {
        entities = dir.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      for (final entity in entities) {
        if (companions.length >= 16) break;
        if (entity is File && entity.path.toLowerCase().endsWith('.exe')) {
          if (entity.path.toLowerCase() == normalized.toLowerCase()) continue;
          if (WindowsInstalledAppsService.isIgnoredExecutable(entity.path)) continue;
          companions.add(entity.path);
        } else if (entity is Directory && depth < 1) {
          final subName = entity.path.split(RegExp(r'[\\/]')).last.toLowerCase();
          if (subName == 'bin' || subName.startsWith('app-') || subName == 'cef' || subName.contains('helper')) {
            collectFrom(entity, depth: depth + 1);
          }
        }
      }
    }

    collectFrom(parent);
    return companions;
  }
}
