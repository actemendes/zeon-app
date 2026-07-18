import 'dart:convert';

import 'package:zeon/core/security/sensitive_text_redactor.dart';

class ErrorReportRedactor {
  const ErrorReportRedactor();

  static const _textRedactor = SensitiveTextRedactor();

  static final _sensitiveKeyPattern = RegExp(
    '(authorization|password|passwd|secret|token|access[_-]?token|refresh[_-]?token|private[_-]?key|public[_-]?key|short[_-]?id|uuid|device[_-]?id|conn(?:ection)?[_-]?link|url|uri)',
    caseSensitive: false,
  );

  Object? redactJson(Object? value) => _redactJson(value, const []);

  Object? _redactJson(Object? value, List<String> path) {
    if (value == null || value is num || value is bool) return value;
    if (value is String) return redactText(value);
    if (value is Iterable) {
      return value.map((entry) => _redactJson(entry, path)).toList(growable: false);
    }
    if (value is Map) {
      return value.map((key, entryValue) {
        final safeKey = key.toString();
        final entryPath = [...path, safeKey];
        if (_isAllowedAppMetadata(entryPath, entryValue)) {
          return MapEntry(safeKey, _sanitizeMetadataValue(entryValue));
        }
        if (_sensitiveKeyPattern.hasMatch(safeKey)) {
          return MapEntry(safeKey, SensitiveTextRedactor.redacted);
        }
        return MapEntry(safeKey, _redactJson(entryValue, entryPath));
      });
    }
    return redactText(value.toString());
  }

  bool _isAllowedAppMetadata(List<String> path, Object? value) {
    if (path.length != 2 || path.first != 'app') return false;
    if (value is! String && value is! num && value is! bool) return false;
    return switch (path.last) {
      'name' || 'version' || 'build_number' || 'environment' || 'release' => true,
      _ => false,
    };
  }

  Object? _sanitizeMetadataValue(Object? value) {
    if (value is String) {
      return _textRedactor.truncate(value.replaceAll('\u0000', '[NUL]'), SensitiveTextRedactor.defaultMaxLength);
    }
    return value;
  }

  Map<String, dynamic> redactMap(Map<String, dynamic> value) {
    final redacted = redactJson(value);
    if (redacted is Map<String, dynamic>) return redacted;
    if (redacted is Map) return redacted.cast<String, dynamic>();
    return <String, dynamic>{};
  }

  String redactText(String input, {int maxLength = SensitiveTextRedactor.defaultMaxLength}) =>
      _textRedactor.redact(input, maxLength: maxLength);

  String truncate(String input, int maxLength) => _textRedactor.truncate(input, maxLength);

  String encodeJson(Object? value) {
    return jsonEncode(redactJson(value));
  }
}
