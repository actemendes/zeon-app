import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/features/button_appearance/button_appearance.dart';
import 'package:zeon/features/button_appearance/data/button_appearance_provider.dart';
import 'package:zeon/features/button_appearance/widget/button_appearance_editor.dart';
import 'package:zeon/features/settings/widget/settings_surface.dart';

class ButtonAppearancePrefTile extends ConsumerWidget {
  const ButtonAppearancePrefTile({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(buttonAppearanceProvider).valueOrNull;
    return SettingsTile(
      title: const Text('Вид кнопки'),
      subtitle: Text(switch (appearance?.preset) {
        ButtonPreset.kawaii => 'Кавайность',
        ButtonPreset.custom => appearance!.name,
        _ => 'Стандартная',
      }),
      leading: const Icon(Icons.palette_outlined),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ButtonAppearancePage())),
    );
  }
}

class ButtonAppearancePage extends ConsumerWidget {
  const ButtonAppearancePage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(buttonAppearanceProvider)
      .when(
        data: (appearance) =>
            ButtonAppearanceEditor(initial: appearance, onSave: ref.read(buttonAppearanceProvider.notifier).save),
        loading: () => Scaffold(
          appBar: AppBar(title: const Text('Вид кнопки')),
          body: const Center(child: CircularProgressIndicator()),
        ),
        error: (_, _) => Scaffold(
          appBar: AppBar(title: const Text('Вид кнопки')),
          body: Center(
            child: TextButton(
              onPressed: () {
                ref.invalidate(buttonAppearanceRepositoryProvider);
                ref.invalidate(buttonAppearanceProvider);
              },
              child: const Text('Не удалось загрузить настройки. Повторить'),
            ),
          ),
        ),
      );
}
