import 'package:zeon/singbox/model/singbox_config_option.dart';
import 'package:zeon/singbox/model/singbox_rule.dart';

/// Keeps ZEON's control-plane API on the selected proxy path.
///
/// A local HTTP proxy alone is not sufficient: sing-box still applies its
/// normal geo/site rules to requests received by the mixed inbound. This rule
/// is prepended after profile overrides so regional or user `direct` rules
/// cannot move control-plane requests outside the VPN.
abstract final class MobileApiProxyRoute {
  static const apiBaseUrl = String.fromEnvironment('mobile_api_base_url', defaultValue: 'https://130.49.151.173');

  /// Returns true only for requests to the configured control-plane origin.
  ///
  /// Keeping this check next to the sing-box rule prevents an HTTP caller from
  /// accidentally opting out with `directOnly`. Paths and query parameters do
  /// not matter; a different host, port, or TLS mode is a different origin.
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

  static SingboxRule? ruleFor(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    final host = uri?.host.trim().toLowerCase() ?? '';
    if (host.isEmpty) return null;

    final ipCidr = _asHostCidr(host);
    if (ipCidr != null) {
      return SingboxRule(ip: ipCidr, outbound: RuleOutbound.proxy);
    }

    return SingboxRule(domains: <String>[host], outbound: RuleOutbound.proxy);
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
}
