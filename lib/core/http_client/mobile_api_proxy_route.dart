import 'dart:convert';

import 'package:zeon/singbox/model/singbox_config_option.dart';
import 'package:zeon/singbox/model/singbox_rule.dart';

/// Keeps ZEON's control-plane API on the selected proxy path while VPN runs.
///
/// A local HTTP proxy alone is not sufficient: sing-box still applies its
/// normal geo/site rules to requests received by the mixed inbound. This rule
/// is prepended after profile overrides so regional or user `direct` rules
/// cannot move proxied control-plane requests outside the VPN. When the local
/// VPN proxy is not running, DioHttpClient connects to this origin directly.
abstract final class MobileApiProxyRoute {
  static const apiBaseUrl = String.fromEnvironment('mobile_api_base_url', defaultValue: 'https://api.zeon-vps.online');

  /// Returns true only for requests to the configured control-plane origin.
  ///
  /// Paths and query parameters do not matter; a different host, port, or TLS
  /// mode is a different origin.
  static bool requiresVpn(String requestUrl, {String baseUrl = apiBaseUrl}) {
    final api = Uri.tryParse(baseUrl.trim());
    final request = Uri.tryParse(requestUrl.trim());
    if (api == null || request == null || api.host.isEmpty || request.host.isEmpty) {
      return false;
    }

    return api.host.toLowerCase() == request.host.toLowerCase() &&
        _isSecure(api.scheme) == _isSecure(request.scheme) &&
        _effectivePort(api) == _effectivePort(request);
  }

  static SingboxConfigOption enforce(SingboxConfigOption options, {String baseUrl = apiBaseUrl}) {
    final rule = ruleFor(baseUrl);
    if (rule == null) return options;

    return options.copyWith(rules: enforceRules(options.rules, baseUrl: baseUrl));
  }

  static List<SingboxRule> enforceRules(List<SingboxRule> rules, {String baseUrl = apiBaseUrl}) {
    final rule = ruleFor(baseUrl);
    if (rule == null) return rules;

    return <SingboxRule>[rule, ...rules.where((existing) => existing != rule)];
  }

  /// Separates early user policy from late profile/global policy.
  ///
  /// Explicit user rules are evaluated immediately after the mandatory route.
  /// Profile-provided rules retain their relative order but are sent in a
  /// separate bucket so the Russia builder can place them after RU DIRECT
  /// destination rules.
  static ({List<Map<String, dynamic>> priorityRules, List<Map<String, dynamic>> profileRules}) planCoreRules({
    required List<Map<String, dynamic>> configuredRules,
    required List<Map<String, dynamic>> userRules,
    String baseUrl = apiBaseUrl,
  }) {
    final mandatoryRule = ruleFor(baseUrl)?.toCoreJson();
    final priority = _distinctCoreRules(<Map<String, dynamic>>[if (mandatoryRule != null) mandatoryRule, ...userRules]);
    final priorityKeys = priority.map(_coreRuleKey).toSet();
    final profile = _distinctCoreRules(
      configuredRules.where((rule) => !priorityKeys.contains(_coreRuleKey(rule))).toList(),
    );

    // zeon-core sorts every enabled rule by list_order before compiling the
    // sing-box config. Re-number each transport bucket so that boundary cannot
    // undo its intended relative order. Persisted rules are untouched.
    return (priorityRules: _withSequentialCoreOrder(priority), profileRules: _withSequentialCoreOrder(profile));
  }

  static SingboxRule? ruleFor(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    final host = uri?.host.trim().toLowerCase() ?? '';
    if (host.isEmpty) return null;

    final ipCidr = _asHostCidr(host);
    if (ipCidr != null) {
      return SingboxRule(ip: ipCidr);
    }

    return SingboxRule(domains: <String>[host]);
  }

  static String? _asHostCidr(String host) {
    final ipv4Parts = host.split('.');
    if (ipv4Parts.length == 4 &&
        ipv4Parts.every((part) {
          final value = int.tryParse(part);
          return value != null && value >= 0 && value <= 255 && value.toString() == part;
        })) {
      return '$host/32';
    }

    // Uri.host strips brackets from a valid IPv6 URL.
    if (host.contains(':')) return '$host/128';
    return null;
  }

  static bool _isSecure(String scheme) => switch (scheme.toLowerCase()) {
    'https' || 'wss' => true,
    'http' || 'ws' => false,
    _ => false,
  };

  static int _effectivePort(Uri uri) {
    if (uri.hasPort) return uri.port;
    return _isSecure(uri.scheme) ? 443 : 80;
  }

  static List<Map<String, dynamic>> _distinctCoreRules(List<Map<String, dynamic>> rules) {
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final rule in rules) {
      final key = _coreRuleKey(rule);
      if (seen.add(key)) {
        result.add(Map<String, dynamic>.from(rule));
      }
    }
    return result;
  }

  static List<Map<String, dynamic>> _withSequentialCoreOrder(List<Map<String, dynamic>> rules) =>
      <Map<String, dynamic>>[
        for (final (index, rule) in rules.indexed) <String, dynamic>{...rule, 'list_order': index},
      ];

  static String _coreRuleKey(Map<String, dynamic> rule) {
    // Presentation/order fields do not alter route matching.
    final keys = rule.keys.where((key) => key != 'list_order' && key != 'name').toList()..sort();
    return jsonEncode(<String, dynamic>{for (final key in keys) key: rule[key]});
  }
}
