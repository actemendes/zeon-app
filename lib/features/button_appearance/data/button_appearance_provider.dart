import 'dart:io';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:zeon/core/directories/directories_provider.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/button_appearance/button_appearance.dart';
import 'package:zeon/features/button_appearance/data/button_appearance_repository.dart';

final buttonAppearanceRepositoryProvider = FutureProvider<ButtonAppearanceRepository>((ref) async {
  final preferences = await ref.watch(sharedPreferencesProvider.future);
  final directories = await ref.watch(appDirectoriesProvider.future);
  return ButtonAppearanceRepository(preferences, Directory(p.join(directories.baseDir.path, 'button-images')));
});

final buttonAppearanceProvider = AsyncNotifierProvider<ButtonAppearanceNotifier, ButtonAppearance>(
  ButtonAppearanceNotifier.new,
);

class ButtonAppearanceNotifier extends AsyncNotifier<ButtonAppearance> {
  bool _saving = false;
  @override
  Future<ButtonAppearance> build() async => (await ref.watch(buttonAppearanceRepositoryProvider.future)).load();

  Future<void> save(ButtonAppearance value) async {
    if (_saving) throw StateError('Save already in progress');
    _saving = true;
    try {
      final store = await ref.read(buttonAppearanceRepositoryProvider.future);
      final saved = await store.save(value);
      state = AsyncData(saved);
    } finally {
      _saving = false;
    }
  }
}
