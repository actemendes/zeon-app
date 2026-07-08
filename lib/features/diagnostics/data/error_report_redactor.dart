import 'dart:convert';

class ErrorReportRedactor {
  const ErrorReportRedactor();

  static const _redacted = '<redacted>';
  static const _maxStringLength = 12000;

  static final _sensitiveKeyPattern = RegExp(
    '(authorization|password|passwd|secret|token|access[_-]?token|refresh[_-]?token|private[_-]?key|public[_-]?key|short[_-]?id|uuid)',
    caseSensitive: false,
  );

  static final _textPatterns = <RegExp>[
    RegExp(r'\b(vless|vmess|trojan|ss|hysteria2?)://\S+', caseSensitive: false),
    RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    RegExp(r'\bBasic\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}:\d{2,5}\b'),
    RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'),
    RegExp(r'\b(public_key|short_id|uuid|password|token|access_token|secret)=([^&\s]+)', caseSensitive: false),
  ];

  Object? redactJson(Object? value) {
    if (value == null || value is num || value is bool) return value;
    if (value is String) return redactText(value);
    if (value is Iterable) {
      return value.map(redactJson).toList(growable: false);
    }
    if (value is Map) {
      return value.map((key, entryValue) {
        final safeKey = key.toString();
        if (_sensitiveKeyPattern.hasMatch(safeKey)) {
          return MapEntry(safeKey, _redacted);
        }
        return MapEntry(safeKey, redactJson(entryValue));
      });
    }
    return redactText(value.toString());
  }

  Map<String, dynamic> redactMap(Map<String, dynamic> value) {
    final redacted = redactJson(value);
    if (redacted is Map<String, dynamic>) return redacted;
    if (redacted is Map) return redacted.cast<String, dynamic>();
    return <String, dynamic>{};
  }

  String redactText(String input, {int maxLength = _maxStringLength}) {
    var safe = input.replaceAll('\u0000', '[NUL]');
    for (final pattern in _textPatterns) {
      if (pattern.pattern.contains('(public_key|short_id')) {
        safe = safe.replaceAllMapped(pattern, (match) => '${match.group(1)}=$_redacted');
      } else {
        safe = safe.replaceAll(pattern, _redacted);
      }
    }
    return truncate(safe, maxLength);
  }

  String truncate(String input, int maxLength) {
    if (input.length <= maxLength) return input;
    return '${input.substring(0, maxLength)}...<truncated ${input.length - maxLength} chars>';
  }

  String encodeJson(Object? value) {
    return jsonEncode(redactJson(value));
  }
}
