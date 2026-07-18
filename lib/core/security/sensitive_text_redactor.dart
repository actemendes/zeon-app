class SensitiveTextRedactor {
  const SensitiveTextRedactor();

  static const redacted = '<redacted>';
  static const defaultMaxLength = 12000;

  static final _textPatterns = <RegExp>[
    RegExp(r'\b(vless|vmess|trojan|ss|hysteria2?)://\S+', caseSensitive: false),
    RegExp(r'\bhttps?://[^\s\]\)]+', caseSensitive: false),
    RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    RegExp(r'\bBasic\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    RegExp(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b'),
    RegExp(r'\bmob_[A-Za-z0-9_-]{16,}\b', caseSensitive: false),
    RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}:\d{2,5}\b'),
    RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'),
    RegExp(
      r'''\b(authorization|password|passwd|secret|token|jwt|api[_-]?key|access[_-]?token|refresh[_-]?token|private[_-]?key|public[_-]?key|license[_-]?key|short[_-]?id|uuid|device[_-]?id|conn(?:ection)?[_-]?link)\s*[:=]\s*["']?([^,;\s\}\)"']+)''',
      caseSensitive: false,
    ),
    RegExp(
      r'(preference\s+\[[^\]]*(?:token|secret|key|config|link|jwt)[^\]]*\][^\r\n]*?\s+to\s+\[)[^\]\r\n]*\]',
      caseSensitive: false,
    ),
  ];

  String redact(String input, {int maxLength = defaultMaxLength}) {
    var safe = input.replaceAll('\u0000', '[NUL]');
    for (final pattern in _textPatterns) {
      if (pattern.pattern.startsWith(r'(preference\s+')) {
        safe = safe.replaceAllMapped(pattern, (match) => '${match.group(1)}$redacted]');
      } else if (pattern.pattern.contains('(authorization|password')) {
        safe = safe.replaceAllMapped(pattern, (match) => '${match.group(1)}=$redacted');
      } else {
        safe = safe.replaceAll(pattern, redacted);
      }
    }
    return truncate(safe, maxLength);
  }

  String truncate(String input, int maxLength) {
    if (input.length <= maxLength) return input;
    return '${input.substring(0, maxLength)}...<truncated ${input.length - maxLength} chars>';
  }
}
