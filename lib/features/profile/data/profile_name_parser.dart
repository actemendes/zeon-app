import 'package:hiddify/utils/link_parsers.dart';

String parseProfileName(String? value) {
  final raw = _decodeIfBase64Like((value ?? '').trim());
  if (raw.isEmpty) {
    return '';
  }

  final hasSeparator = raw.contains('|');
  final withoutPrefix = hasSeparator ? raw.split('|').skip(1).join('|').trim() : raw;
  final normalized = withoutPrefix.replaceAll('|', ' ').replaceAll('_', ' ');
  return normalized.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _decodeIfBase64Like(String raw) {
  var candidate = raw.trim();
  if (candidate.toLowerCase().startsWith('base64:')) {
    candidate = candidate.substring(7).trim();
  }

  if (candidate.length < 12) return raw;
  if (!RegExp(r'^[A-Za-z0-9+/_=-]+$').hasMatch(candidate)) return raw;
  if (!(candidate.contains('=') || candidate.contains('_') || candidate.contains('-') || candidate.length % 4 == 0)) {
    return raw;
  }

  final decoded = safeDecodeBase64(candidate).trim();
  if (decoded.isEmpty || decoded == candidate) return raw;
  if (!_isLikelyLabel(decoded)) return raw;
  return decoded;
}

bool _isLikelyLabel(String value) {
  if (value.trim().isEmpty) return false;
  var hasVisibleChar = false;
  for (final rune in value.runes) {
    if (rune == 9 || rune == 10 || rune == 13) continue;
    if (rune < 32) return false;
    if (rune != 32) hasVisibleChar = true;
  }
  return hasVisibleChar;
}
