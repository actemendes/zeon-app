import 'package:flutter/widgets.dart';
import 'package:zeon/core/localization/translation_loader.dart';
import 'package:zeon/gen/translations.g.dart';

/// Localized text for presentation widgets that do not use Riverpod.
/// Reading Flutter's locale also rebuilds these widgets when it changes.
extension TranslationContext on BuildContext {
  Translations get translations => Localizations.of<Translations>(this, Translations) ?? AppLocale.en.buildSync();
}

/// Waits for Slang's deferred catalog before Flutter switches the UI locale.
class InterfaceTranslationsDelegate extends LocalizationsDelegate<Translations> {
  const InterfaceTranslationsDelegate();

  @override
  bool isSupported(Locale locale) => AppLocale.values.any((value) => value.languageCode == locale.languageCode);

  @override
  Future<Translations> load(Locale locale) => loadTranslations(
    AppLocaleUtils.parseLocaleParts(
      languageCode: locale.languageCode,
      scriptCode: locale.scriptCode,
      countryCode: locale.countryCode,
    ),
  );

  @override
  bool shouldReload(InterfaceTranslationsDelegate old) => false;
}
