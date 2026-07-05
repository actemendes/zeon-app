import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

const String autoSelectionDisplayName = 'Автовыбор';
const String autoSelectionSeparator = '•';

/// Returns the user-facing name exactly as supplied by Core/config.
///
/// This deliberately does not remove flags, subscription labels (such as
/// `| БЫСТРЫЙ`) or any other portion of a normal proxy display name.
String formatProxyDisplayName(String raw) {
  final value = raw.trim();
  return _isAutoSelectionName(value) ? autoSelectionDisplayName : value;
}

String formatOutboundTitle(OutboundInfo outbound) => resolveOutboundDisplayInfo(outbound).title;

String formatSelectedServerTitle({
  required bool isAutoSelected,
  required String? selectedName,
  required String? realOutboundName,
  required String? realOutboundFlag,
}) {
  if (!isAutoSelected) {
    final name = selectedName?.trim().isNotEmpty == true ? selectedName!.trim() : realOutboundName?.trim() ?? '';
    return _withoutLeadingFlag(name);
  }

  final realName = displayNameFromRealOutbound(realOutboundName);
  if (realName == null) return autoSelectionDisplayName;

  // Flutter renders the flag in a separate leading widget. This branch keeps
  // the helper usable in notification/text-only contexts as well.
  final flag = _flagEmoji(realOutboundFlag);
  final title =
      '$autoSelectionDisplayName $autoSelectionSeparator ${flag == null ? realName : _withoutLeadingFlag(realName)}';
  return flag == null ? title : '$flag $title';
}

class ServerDisplayInfo {
  const ServerDisplayInfo({required this.title, this.countryCode});

  final String title;
  final String? countryCode;
}

ServerDisplayInfo resolveOutboundDisplayInfo(OutboundInfo outbound, {Iterable<OutboundInfo> allOutbounds = const []}) {
  final isAuto = isAutoSelectedOutbound(outbound);
  final realOutbound = isAuto ? resolveRealOutbound(outbound, allOutbounds: allOutbounds) : null;
  final realName =
      realOutbound?.tagDisplay ??
      (outbound.hasGroupSelectedTagDisplay() ? outbound.groupSelectedTagDisplay : null) ??
      extractRealOutboundTag(outbound.tagDisplay);
  final countryCode = realOutbound == null
      ? resolveProxyCountryCode(
          tagDisplay: realName ?? outbound.tagDisplay,
          fallbackCountryCode: isAuto ? null : outbound.ipinfo.countryCode,
        )
      : resolveProxyCountryCode(
          tagDisplay: realOutbound.tagDisplay,
          fallbackCountryCode: realOutbound.ipinfo.countryCode,
        );

  return ServerDisplayInfo(
    // The list/card uses a leading flag widget, so avoid a duplicate emoji in
    // its text. The real outbound name itself remains untouched.
    title: formatSelectedServerTitle(
      isAutoSelected: isAuto,
      selectedName: outbound.tagDisplay,
      realOutboundName: isAuto ? _withoutLeadingFlag(realName ?? '') : realName,
      realOutboundFlag: null,
    ),
    countryCode: countryCode,
  );
}

bool isAutoSelectedOutbound(OutboundInfo outbound) =>
    _isAutoSelectionName(outbound.tag) ||
    _isAutoSelectionName(outbound.tagDisplay) ||
    outbound.type.trim().toLowerCase() == 'balancer';

/// Only rejects technical selector values; it never transforms a valid name.
String? displayNameFromRealOutbound(String? value) {
  final name = value?.trim();
  if (name == null || name.isEmpty || _isTechnicalSelectionName(name)) return null;
  return name;
}

String? extractRealOutboundTag(String value) {
  final match = RegExp(
    r'^\s*(?:balance|auto|lowest|urltest|Автовыбор)\s*(?:->|>|→|•)\s*(.+?)\s*$',
    caseSensitive: false,
  ).firstMatch(value);
  return match?.group(1)?.trim();
}

String? findOutboundDisplayNameByTag(Iterable<OutboundInfo> items, String? tag) =>
    findOutboundByTagOrDisplay(items, tag)?.tagDisplay;

OutboundInfo? findOutboundByTagOrDisplay(Iterable<OutboundInfo> items, String? candidate) {
  final value = candidate?.trim();
  if (value == null || value.isEmpty) return null;
  final key = _matchKey(value);
  for (final item in items) {
    if (item.tag == value || item.tagDisplay.trim() == value) return item;
    if (_matchKey(item.tag) == key || _matchKey(item.tagDisplay) == key) return item;
  }
  return null;
}

OutboundInfo? resolveRealOutbound(OutboundInfo autoOutbound, {Iterable<OutboundInfo> allOutbounds = const []}) {
  return findOutboundByTagOrDisplay(
        allOutbounds,
        autoOutbound.hasGroupSelectedTag() ? autoOutbound.groupSelectedTag : null,
      ) ??
      findOutboundByTagOrDisplay(
        allOutbounds,
        autoOutbound.hasGroupSelectedTagDisplay() ? autoOutbound.groupSelectedTagDisplay : null,
      ) ??
      findOutboundByTagOrDisplay(allOutbounds, extractRealOutboundTag(autoOutbound.tagDisplay));
}

String? resolveRealOutboundTag({required OutboundInfo autoOutbound, required Iterable<OutboundInfo> allOutbounds}) =>
    resolveRealOutbound(autoOutbound, allOutbounds: allOutbounds)?.tag;

String? resolveProxyCountryCode({required String tagDisplay, String? fallbackCountryCode}) =>
    _extractCountryCodeFromFlagEmoji(tagDisplay) ?? _normalizeCountryCode(fallbackCountryCode);

bool shouldHideProxyOption({required String tag, required String tagDisplay}) {
  final rawTag = tag.trim().toLowerCase();
  final rawDisplay = tagDisplay.trim().toLowerCase();
  return rawTag == 'lowest' ||
      rawDisplay == 'lowest' ||
      RegExp(r'авто\s*\|', caseSensitive: false).hasMatch(rawTag) ||
      RegExp(r'авто\s*\|', caseSensitive: false).hasMatch(rawDisplay);
}

bool _isAutoSelectionName(String value) {
  switch (_matchKey(value).toLowerCase()) {
    case 'balance':
    case 'auto':
    case 'lowest':
    case 'urltest':
    case 'автовыбор':
      return true;
    default:
      return false;
  }
}

bool _isTechnicalSelectionName(String value) {
  switch (_matchKey(value).toLowerCase()) {
    case '':
    case 'select':
    case 'selector':
    case 'balance':
    case 'auto':
    case 'lowest':
    case 'urltest':
    case 'round-robin':
    case 'roundrobin':
    case 'автовыбор':
      return true;
    default:
      return false;
  }
}

// Tag normalization is used exclusively for matching Core tags. It is never
// used for text shown to the user.
String _matchKey(String value) => value.split('В§').first.split('§').first.trim();

String? _normalizeCountryCode(String? value) {
  final normalized = value?.trim().toUpperCase();
  if (normalized == null || normalized.length != 2) return null;
  return normalized.runes.every((r) => r >= 65 && r <= 90) ? normalized : null;
}

String? _extractCountryCodeFromFlagEmoji(String value) {
  final runes = value.runes.toList();
  for (var i = 0; i < runes.length - 1; i++) {
    if (_isRegionalIndicator(runes[i]) && _isRegionalIndicator(runes[i + 1])) {
      return '${String.fromCharCode(runes[i] - 0x1F1E6 + 65)}${String.fromCharCode(runes[i + 1] - 0x1F1E6 + 65)}';
    }
  }
  return null;
}

String? _flagEmoji(String? countryCode) {
  final normalized = _normalizeCountryCode(countryCode);
  if (normalized == null) return null;
  return String.fromCharCodes(normalized.runes.map((rune) => 0x1F1E6 + rune - 65));
}

bool _isRegionalIndicator(int rune) => rune >= 0x1F1E6 && rune <= 0x1F1FF;

// Used only when an Auto row renders the country flag in its leading widget.
// It removes that duplicate visual flag but leaves every word and suffix of
// the original display name intact.
String _withoutLeadingFlag(String value) {
  final runes = value.runes.toList();
  if (runes.length < 2 || !_isRegionalIndicator(runes[0]) || !_isRegionalIndicator(runes[1])) return value;
  return String.fromCharCodes(runes.skip(2)).replaceFirst(RegExp(r'^[\s\-:•·]+'), '').trim();
}
