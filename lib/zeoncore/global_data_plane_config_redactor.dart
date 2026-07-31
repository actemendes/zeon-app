import 'dart:convert';

/// Produces a comparison-oriented effective-config snapshot without retaining
/// profile credentials, endpoint identities, custom domains, package names or
/// filesystem paths. The output is evidence, not a runnable configuration.
final class GlobalDataPlaneConfigRedactor {
  GlobalDataPlaneConfigRedactor();

  static const _preservedTags = <String>{
    'block',
    'bypass',
    'default',
    'direct',
    'dns',
    'dns-direct',
    'dns-remote',
    'final',
    'hiddify-out',
    'local',
    'mixed-in',
    'proxy',
    'remote',
    'select',
    'selector',
    'tun-in',
    'url-test',
    'urltest',
    'zapret-ru-domains',
    'zapret-ru-ip',
    'zeon-ru-wildberries',
    'zeon-ru-yandex',
  };

  static const _secretKeys = <String>{
    'access_token',
    'authorization',
    'certificate',
    'client_certificate',
    'client_key',
    'headers',
    'password',
    'private_key',
    'public_key',
    'service_name',
    'secret',
    'short_id',
    'token',
    'username',
    'uuid',
  };

  static const _endpointKeys = <String>{
    'address',
    'endpoint',
    'external_controller',
    'host',
    'hostname',
    'listen',
    'server',
    'server_name',
    'server_port',
    'udp_probe_endpoint',
  };

  static const _pathKeys = <String>{'cache_file', 'database_path', 'output', 'path', 'rule_set_path'};

  static const _destinationListKeys = <String>{
    'domain',
    'domain_keyword',
    'domain_regex',
    'domain_suffix',
    'ip_cidr',
    'package_name',
    'process_name',
    'process_path',
    'source_ip_cidr',
  };

  final Map<String, String> _tagAliases = <String, String>{};
  int _nextTag = 1;

  Object? redact(Object? input) {
    _tagAliases.clear();
    _nextTag = 1;
    _collectTags(input);
    return _redactValue(input, key: null);
  }

  String redactJson(String source) {
    final decoded = jsonDecode(source);
    return const JsonEncoder.withIndent('  ').convert(redact(decoded));
  }

  void _collectTags(Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString();
        if (key == 'tag' && entry.value is String) {
          _aliasTag(entry.value as String);
        }
        _collectTags(entry.value);
      }
    } else if (value is List) {
      for (final item in value) {
        _collectTags(item);
      }
    }
  }

  Object? _redactValue(Object? value, {required String? key}) {
    final normalizedKey = key?.toLowerCase();
    if (normalizedKey != null && _isSecretKey(normalizedKey)) {
      return '<redacted-secret>';
    }
    if (normalizedKey != null && _isEndpointKey(normalizedKey)) {
      return _describeEndpoint(value);
    }
    if (normalizedKey != null && _pathKeys.contains(normalizedKey)) {
      return '<redacted-path>';
    }
    if (normalizedKey != null && _destinationListKeys.contains(normalizedKey)) {
      return _describeDestinationValues(value);
    }
    if (normalizedKey != null && _isTagReferenceKey(normalizedKey)) {
      if (value is String) return _aliasTag(value);
      if (value is List && value.every((item) => item is String)) {
        return value.cast<String>().map(_aliasTag).toList();
      }
    }
    if (normalizedKey != null && _looksLikeUrlKey(normalizedKey)) {
      return _describeUrl(value);
    }
    if (value is Map) {
      final result = <String, Object?>{};
      final entries = value.entries.toList()..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
      for (final entry in entries) {
        final childKey = entry.key.toString();
        result[childKey] = _redactValue(entry.value, key: childKey);
      }
      return result;
    }
    if (value is List) {
      return value.map((item) => _redactValue(item, key: normalizedKey)).toList();
    }
    if (value is String && _looksSensitiveString(value)) {
      return '<redacted-string>';
    }
    return value;
  }

  bool _isTagReferenceKey(String key) =>
      key == 'tag' ||
      key == 'outbound' ||
      key == 'outbounds' ||
      key == 'detour' ||
      key == 'default' ||
      key == 'final' ||
      key == 'domain_resolver' ||
      key == 'download_detour' ||
      key == 'rule_set' ||
      key == 'rule_sets';

  bool _isSecretKey(String key) =>
      _secretKeys.contains(key) ||
      key.endsWith('_password') ||
      key.endsWith('_private_key') ||
      key.endsWith('_public_key') ||
      key.endsWith('_secret') ||
      key.endsWith('_token');

  bool _isEndpointKey(String key) =>
      _endpointKeys.contains(key) || key.endsWith('_endpoint') || key.endsWith('_server_name');

  bool _looksLikeUrlKey(String key) => key == 'url' || key.endsWith('_url') || key == 'urls';

  String _aliasTag(String value) {
    final normalized = value.trim();
    final lower = normalized.toLowerCase();
    if (_preservedTags.contains(lower)) return lower;
    return _tagAliases.putIfAbsent(normalized, () => 'tag-${(_nextTag++).toString().padLeft(3, '0')}');
  }

  Object _describeEndpoint(Object? value) {
    if (value is int || value is num) return '<redacted-endpoint-number>';
    if (value is! String || value.isEmpty) return '<redacted-endpoint>';
    final kind = value.contains(':')
        ? 'ipv6-or-host-port'
        : value.split('.').length == 4
        ? 'ipv4-or-host'
        : 'hostname';
    return '<redacted-endpoint:$kind>';
  }

  Object _describeUrl(Object? value) {
    if (value is List) return value.map(_describeUrl).toList();
    if (value is! String) return '<redacted-url>';
    final uri = Uri.tryParse(value);
    return '<redacted-url:${uri?.scheme.isNotEmpty == true ? uri!.scheme.toLowerCase() : 'unknown'}>';
  }

  Object _describeDestinationValues(Object? value) {
    final values = value is List ? value : <Object?>[value];
    var ipv4 = 0;
    var ipv6 = 0;
    var other = 0;
    for (final item in values) {
      final text = item?.toString() ?? '';
      if (RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}(?:/\d{1,2})?$').hasMatch(text)) {
        ipv4++;
      } else if (text.contains(':')) {
        ipv6++;
      } else {
        other++;
      }
    }
    return <String, Object>{'count': values.length, 'ipv4Like': ipv4, 'ipv6Like': ipv6, 'other': other};
  }

  bool _looksSensitiveString(String value) {
    if (value.contains('://') || value.contains('-----BEGIN ')) return true;
    if (RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$').hasMatch(value)) return true;
    return false;
  }
}
