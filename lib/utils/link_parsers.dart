import 'dart:convert';

import 'package:hiddify/utils/validators.dart';

typedef ProfileLink = ({String url, String name});

// TODO: test and improve
abstract class LinkParser {
  static const _mobileApiBaseUrl = String.fromEnvironment(
    "mobile_api_base_url",
    defaultValue: "https://130.49.151.173",
  );
  static const _mobilePublicOpenBaseUrl = "https://zeon-vps.link";

  static String generateSubShareLink(String url, [String? name]) {
    final publicUrl = toPublicOpenProfileLink(url);
    final uri = Uri.tryParse(publicUrl);
    if (uri == null) return '';
    final modifiedUri = Uri(
      scheme: uri.scheme,
      host: uri.host,
      path: uri.path,
      query: uri.query,
      fragment: name ?? uri.fragment,
    );
    // return 'hiddify://import/$modifiedUri';
    return '$modifiedUri';
  }

  static String toPublicOpenProfileLink(String rawUrl) {
    final input = rawUrl.trim();
    if (input.isEmpty) return input;
    final uri = Uri.tryParse(input);
    if (uri == null) return input;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return input;
    if (!uri.path.toLowerCase().startsWith('/open/')) return input;

    final apiBase = Uri.tryParse(_mobileApiBaseUrl);
    final publicBase = Uri.tryParse(_mobilePublicOpenBaseUrl);
    if (apiBase == null || publicBase == null) return input;

    final isApiHost = uri.host.toLowerCase() == apiBase.host.toLowerCase();
    if (!isApiHost) return input;

    return uri
        .replace(
          scheme: publicBase.scheme.isEmpty ? uri.scheme : publicBase.scheme,
          host: publicBase.host,
          port: publicBase.hasPort ? publicBase.port : null,
        )
        .toString();
  }

  // protocols schemas
  static const protocols = ['zeon', 'hiddify', 'v2ray', 'v2rayn', 'v2rayng', 'clash', 'clashmeta', 'sing-box'];

  static ProfileLink? parse(String link) {
    return simple(link) ?? deep(link);
  }

  static ProfileLink? simple(String link) {
    if (!isUrl(link)) return null;
    final uri = Uri.parse(link.trim());
    return (url: uri.toString(), name: uri.queryParameters['name'] ?? '');
  }

  static ProfileLink? deep(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) return null;
    final queryParams = uri.queryParameters;
    switch (uri.scheme) {
      case 'zeon' || 'hiddify':
        if (queryParams.containsKey('url')) {
          return (url: queryParams['url']!, name: queryParams['name'] ?? '');
        } else {
          return (url: uri.path.substring(1) + (uri.hasQuery ? "?${uri.query}" : ""), name: uri.fragment);
        }
      case 'v2ray' || 'v2rayn' || 'v2rayng' || 'clash' || 'clashmeta' || 'sing-box':
        return queryParams.containsKey('url') ? (url: queryParams['url']!, name: queryParams['name'] ?? '') : null;
      default:
        return null;
    }
  }
}

String safeDecodeBase64(String str) {
  try {
    final value = str.trim();
    if (value.isEmpty) return value;

    String normalize(String input) {
      var out = input.replaceAll('-', '+').replaceAll('_', '/');
      final mod = out.length % 4;
      if (mod != 0) {
        out = out.padRight(out.length + (4 - mod), '=');
      }
      return out;
    }

    return utf8.decode(base64Decode(normalize(value)));
  } catch (e) {
    return str;
  }
}
