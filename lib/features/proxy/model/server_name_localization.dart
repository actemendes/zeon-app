import 'package:zeon/features/proxy/model/server_country_names.dart';
import 'package:zeon/gen/translations.g.dart';

final _countryNames = Expando<Map<String, String>>();

final _countryPrefix = RegExp(
  r'^(\s*(?:(?:[\u{1F1E6}-\u{1F1FF}]{2}|🏳\uFE0F?)\s*)?)' +
      '(${(russianServerCountryCodes.keys.toList()..sort((a, b) => b.length.compareTo(a.length))).map(RegExp.escape).join('|')})' +
      r'(?=\s*(?:#?\d+)?\s*(?:\||$))',
  caseSensitive: false,
  unicode: true,
);

final _serverLabel = RegExp(
  r'(\|\s*)(БЫСТРЫЙ|СВЯЗЬ)(?=\s*(?:[⚡📱]\uFE0F?)?\s*(?:\||$))',
  caseSensitive: false,
  unicode: true,
);

/// Translates only the recognized parts of a backend display name.
/// Never use this result as a Core tag, selector key or persisted profile name.
String localizeServerDisplayName(String raw, Translations translations) {
  if (translations.$meta.locale == AppLocale.ru) return raw;
  final names = translations.pages.proxies.serverNames;
  final country = _countryPrefix.firstMatch(raw);
  var result = raw;
  if (country != null) {
    final code = russianServerCountryCodes[country.group(2)!.toLowerCase()];
    final countries = _countryNames[translations] ??= names.countries;
    final translated = code == 'ZZ' ? translations.common.unknown : countries[code];
    if (translated != null) {
      result = '${country.group(1)}$translated${raw.substring(country.end)}';
    }
  }
  return result.replaceAllMapped(_serverLabel, (match) {
    final label = match.group(2)!.toUpperCase() == 'БЫСТРЫЙ' ? names.fast : names.bypass;
    return '${match.group(1)}$label';
  });
}
