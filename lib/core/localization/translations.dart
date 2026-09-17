import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:zeon/core/localization/locale_preferences.dart';
import 'package:zeon/core/localization/translation_loader.dart';
import 'package:zeon/gen/translations.g.dart';

export 'package:zeon/gen/translations.g.dart';

part 'translations.g.dart';

@Riverpod(keepAlive: true)
Future<Translations> translations(Ref ref) async {
  return await loadTranslations(ref.watch(localePreferencesProvider));
}
