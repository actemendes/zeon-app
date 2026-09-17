import 'package:intl/intl.dart';
import 'package:zeon/gen/translations.g.dart';

/// Slang 4.8 does not ship plural rules for every supported app language.
/// Use the same CLDR rules for provider-driven UI and Flutter localizations.
Future<Translations> loadTranslations(AppLocale locale) => locale.build(
  cardinalResolver: (n, {zero, one, two, few, many, other}) => Intl.pluralLogic(
    n,
    locale: locale.languageTag.replaceAll('-', '_'),
    zero: zero,
    one: one,
    two: two,
    few: few,
    many: many,
    other: other ?? '',
  ),
);
