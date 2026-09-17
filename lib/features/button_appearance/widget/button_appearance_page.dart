import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translation_context.dart';
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
      title: Text(context.translations.buttonAppearance.title),
      subtitle: Text(switch (appearance?.preset) {
        ButtonPreset.kawaii => context.translations.buttonAppearance.kawaii,
        ButtonPreset.custom =>
          appearance!.name.isEmpty ? context.translations.buttonAppearance.defaultName : appearance.name,
        _ => context.translations.buttonAppearance.standard,
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
          appBar: AppBar(title: Text(context.translations.buttonAppearance.title)),
          body: const Center(child: CircularProgressIndicator()),
        ),
        error: (_, _) => Scaffold(
          appBar: AppBar(title: Text(context.translations.buttonAppearance.title)),
          body: Center(
            child: TextButton(
              onPressed: () {
                ref.invalidate(buttonAppearanceRepositoryProvider);
                ref.invalidate(buttonAppearanceProvider);
              },
              child: Text(context.translations.buttonAppearance.loadError),
            ),
          ),
        ),
      );
}
