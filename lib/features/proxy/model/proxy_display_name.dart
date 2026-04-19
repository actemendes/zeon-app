String formatProxyDisplayName(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return value;

  value = _stripLeadingFlag(value);
  value = value.replaceAll(RegExp(r"\s*(?:->|\u2192)\s*round-?robin\s*$", caseSensitive: false), "");

  if (RegExp(r"^balance$", caseSensitive: false).hasMatch(value)) {
    return "\u0410\u0432\u0442\u043e\u0432\u044b\u0431\u043e\u0440 \u0441\u0435\u0440\u0432\u0435\u0440\u0430"; // Автовыбор сервера
  }

  return value.trim();
}

String? resolveProxyCountryCode({required String tagDisplay, String? fallbackCountryCode}) {
  final fromFlag = _extractCountryCodeFromFlagEmoji(tagDisplay);
  if (fromFlag != null) return fromFlag;
  return _normalizeCountryCode(fallbackCountryCode);
}

String? _normalizeCountryCode(String? value) {
  if (value == null) return null;
  final normalized = value.trim().toUpperCase();
  if (normalized.length != 2) return null;
  final runes = normalized.runes.toList();
  final isLetters = runes.every((r) => r >= 65 && r <= 90);
  return isLetters ? normalized : null;
}

String? _extractCountryCodeFromFlagEmoji(String value) {
  final runes = value.runes.toList();
  for (var i = 0; i < runes.length - 1; i++) {
    final first = runes[i];
    final second = runes[i + 1];
    if (_isRegionalIndicator(first) && _isRegionalIndicator(second)) {
      final firstLetter = String.fromCharCode((first - 0x1F1E6) + 65);
      final secondLetter = String.fromCharCode((second - 0x1F1E6) + 65);
      return "$firstLetter$secondLetter";
    }
  }
  return null;
}

bool _isRegionalIndicator(int rune) => rune >= 0x1F1E6 && rune <= 0x1F1FF;

String _stripLeadingFlag(String value) {
  final runes = value.runes.toList();
  if (runes.length < 2) return value.trim();
  if (!_isRegionalIndicator(runes[0]) || !_isRegionalIndicator(runes[1])) return value.trim();

  final rest = String.fromCharCodes(runes.skip(2));
  return rest.replaceFirst(RegExp(r"^[\s\-\|:\u2022\u00B7]+"), "").trim();
}

bool shouldHideProxyOption({required String tag, required String tagDisplay}) {
  final rawTag = tag.trim().toLowerCase();
  final rawDisplay = tagDisplay.trim().toLowerCase();
  return rawTag == "lowest" || rawDisplay == "lowest";
}
