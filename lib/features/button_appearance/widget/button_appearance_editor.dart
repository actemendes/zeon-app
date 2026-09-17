import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:zeon/features/button_appearance/data/button_image_codec.dart';
import 'package:zeon/features/button_appearance/widget/custom_vpn_button.dart';

typedef PickButtonImage = Future<Uint8List?> Function();
Future<Uint8List?> pickButtonImage() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
    withData: true,
  );
  return result?.files.single.bytes;
}

class ButtonAppearanceEditor extends StatefulWidget {
  const ButtonAppearanceEditor({
    super.key,
    this.initial = const ButtonAppearance(),
    required this.onSave,
    this.pickImage = pickButtonImage,
    this.onBack,
    this.animate = true,
  });
  final ButtonAppearance initial;
  final Future<void> Function(ButtonAppearance) onSave;
  final PickButtonImage pickImage;
  final VoidCallback? onBack;
  final bool animate;
  @override
  State<ButtonAppearanceEditor> createState() => _ButtonAppearanceEditorState();
}

class _ButtonAppearanceEditorState extends State<ButtonAppearanceEditor> {
  late ButtonPreset preset = widget.initial.preset;
  late final Map<ButtonPhase, ButtonPicture> pictures = {...widget.initial.pictures};
  late final name = TextEditingController(text: widget.initial.name);
  ButtonPhase previewPhase = ButtonPhase.connected;
  bool busy = false;
  ButtonAppearance get draft =>
      ButtonAppearance(preset: preset, pictures: Map.unmodifiable(pictures), name: name.text.trim());
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> choose(ButtonPhase phase) async {
    setState(() => busy = true);
    try {
      final bytes = await widget.pickImage();
      if (bytes == null || !mounted) return;
      if (bytes.length > 15 * 1024 * 1024) throw const FormatException('Размер изображения — до 15 МБ');
      // Decode before accepting a file, so corrupt data cannot replace a working slot.
      final normalized = await normalizeButtonImage(bytes);
      if (!mounted) return;
      final result = await showDialog<ButtonPicture>(
        context: context,
        builder: (_) => PictureCropDialog(picture: ButtonPicture(MemoryImage(normalized))),
      );
      if (result != null && mounted) {
        setState(() {
          pictures[phase] = result;
          previewPhase = phase;
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось открыть изображение. Выберите PNG, JPG или WebP до 15 МБ.')),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    final value = draft;
    setState(() => busy = true);
    try {
      await widget.onSave(value);
      if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Не удалось сохранить вид кнопки. Попробуйте ещё раз.')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final custom = preset == ButtonPreset.custom;
    final canSave = !busy && (!custom || (draft.complete && draft.name.isNotEmpty));
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: busy ? null : (widget.onBack ?? () => Navigator.maybePop(context)),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          title: const Text('Вид кнопки'),
          centerTitle: true,
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          children: [
            const Text('Выберите настроение', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              'Готовый набор или Ваши изображения\nдля каждого состояния.',
              style: TextStyle(fontSize: 12, height: 1.5, color: c.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                for (final p in ButtonPreset.values) ...[
                  if (p.index > 0) const SizedBox(width: 7),
                  Expanded(child: _presetTile(p)),
                ],
              ],
            ),
            const SizedBox(height: 21),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 15, 12, 12),
              decoration: BoxDecoration(
                color: c.surfaceContainerHigh.withValues(alpha: .65),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                children: [
                  Text('ПРЕДПРОСМОТР', style: TextStyle(fontSize: 9, letterSpacing: 1.5, color: c.onSurfaceVariant)),
                  const SizedBox(height: 12),
                  CustomVpnButton(
                    phase: previewPhase,
                    appearance: draft,
                    diameter: 138,
                    animate: widget.animate,
                    onPressed: () => setState(() => previewPhase = ButtonPhase.values[(previewPhase.index + 1) % 3]),
                  ),
                  const SizedBox(height: 13),
                  PhaseSelector(phase: previewPhase, onChanged: (p) => setState(() => previewPhase = p)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (custom) ...[
              TextField(
                key: const ValueKey('preset-name'),
                controller: name,
                onChanged: (_) => setState(() {}),
                maxLength: 32,
                decoration: const InputDecoration(labelText: 'Название набора', counterText: '', isDense: true),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Ваши изображения', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  Text('${pictures.length} / 3', style: TextStyle(fontSize: 12, color: c.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 8),
              for (final phase in ButtonPhase.values) _slot(phase),
              const SizedBox(height: 7),
              Text(
                'PNG, JPG, WebP · до 15 МБ\nКадрирование настраивается после выбора.',
                style: TextStyle(fontSize: 10, height: 1.5, color: c.onSurfaceVariant),
              ),
            ] else ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: c.surfaceContainerHigh, borderRadius: BorderRadius.circular(16)),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.auto_awesome_outlined, size: 19),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        preset == ButtonPreset.standard
                            ? 'Классическая кнопка ZEON с логотипом и большим кольцом.'
                            : 'Картинка меняется вместе с состоянием. Тонкое кольцо оставляет больше места персонажу.',
                        style: const TextStyle(fontSize: 11, height: 1.55),
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => setState(() {
                  pictures.addAll({
                    for (final p in ButtonPhase.values)
                      if (draft.pictureFor(p) != null) p: draft.pictureFor(p)!,
                  });
                  preset = ButtonPreset.custom;
                }),
                child: const Text('Создать свой на основе набора', style: TextStyle(fontSize: 11)),
              ),
            ],
          ],
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 15),
            child: SizedBox(
              height: 48,
              child: FilledButton(
                key: const ValueKey('save-appearance'),
                onPressed: canSave ? save : null,
                child: Text(custom ? 'Сохранить и применить' : 'Применить'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _presetTile(ButtonPreset p) {
    final c = Theme.of(context).colorScheme;
    final selected = preset == p;
    final label = ['Стандартная', 'Кавайность', 'Своя'][p.index];
    return Semantics(
      selected: selected,
      child: InkWell(
        key: ValueKey('preset-${p.name}'),
        borderRadius: BorderRadius.circular(17),
        onTap: busy ? null : () => setState(() => preset = p),
        child: Container(
          height: 108,
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
          decoration: BoxDecoration(
            color: c.surfaceContainerHigh,
            border: Border.all(color: selected ? zeonGreen : Colors.transparent, width: 2),
            borderRadius: BorderRadius.circular(17),
          ),
          child: Column(
            children: [
              SizedBox.square(
                dimension: 46,
                child: ClipOval(
                  child: p == ButtonPreset.standard
                      ? Padding(
                          padding: const EdgeInsets.all(8),
                          child: Image.asset('assets/images/2x/logo-black_1@2x.png', color: c.onSurface),
                        )
                      : p == ButtonPreset.custom
                      ? const Icon(Icons.add_photo_alternate_outlined, size: 27)
                      : PictureFace(picture: ButtonAppearance(preset: p).pictureFor(ButtonPhase.connected)),
                ),
              ),
              const SizedBox(height: 9),
              FittedBox(
                child: Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 5),
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(shape: BoxShape.circle, color: selected ? zeonGreen : Colors.transparent),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _slot(ButtonPhase phase) {
    final c = Theme.of(context).colorScheme;
    final filled = pictures[phase] != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: c.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(15),
        child: InkWell(
          key: ValueKey('slot-${phase.name}'),
          borderRadius: BorderRadius.circular(15),
          onTap: busy ? null : () => choose(phase),
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 44,
                  child: ClipOval(child: PictureFace(picture: pictures[phase])),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(phase.label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(
                        filled ? 'Заменить изображение' : 'Выбрать изображение',
                        style: TextStyle(fontSize: 10, color: c.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (filled)
                  IconButton(
                    tooltip: 'Удалить изображение',
                    onPressed: busy ? null : () => setState(() => pictures.remove(phase)),
                    icon: const Icon(Icons.close_rounded, size: 17),
                  )
                else
                  const Padding(padding: EdgeInsets.all(10), child: Icon(Icons.add_rounded, size: 20)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PhaseSelector extends StatelessWidget {
  const PhaseSelector({super.key, required this.phase, required this.onChanged});
  final ButtonPhase phase;
  final ValueChanged<ButtonPhase> onChanged;
  @override
  Widget build(BuildContext context) => Row(
    children: ButtonPhase.values
        .map(
          (p) => Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Material(
                borderRadius: BorderRadius.circular(10),
                color: phase == p ? Theme.of(context).scaffoldBackgroundColor : Colors.transparent,
                child: InkWell(
                  key: ValueKey('phase-${p.name}'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => onChanged(p),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 2),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        p.label,
                        style: TextStyle(fontSize: 10, fontWeight: phase == p ? FontWeight.w700 : FontWeight.w500),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        )
        .toList(),
  );
}

class PictureCropDialog extends StatefulWidget {
  const PictureCropDialog({super.key, required this.picture});
  final ButtonPicture picture;
  @override
  State<PictureCropDialog> createState() => _PictureCropDialogState();
}

class _PictureCropDialogState extends State<PictureCropDialog> {
  double zoom = 1;
  Alignment alignment = Alignment.center;
  @override
  Widget build(BuildContext context) {
    final picture = ButtonPicture(widget.picture.image, zoom: zoom, alignment: alignment);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Настройте кадр', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text(
                  'Переместите картинку и выберите масштаб.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, height: 1.5),
                ),
                const SizedBox(height: 22),
                GestureDetector(
                  onPanUpdate: (d) => setState(
                    () => alignment = Alignment(
                      (alignment.x - d.delta.dx / 90).clamp(-1.0, 1.0),
                      (alignment.y - d.delta.dy / 90).clamp(-1.0, 1.0),
                    ),
                  ),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: ClipOval(child: PictureFace(picture: picture)),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(Icons.zoom_out_rounded),
                    Expanded(
                      child: Slider(value: zoom, min: 1, max: 3, onChanged: (v) => setState(() => zoom = v)),
                    ),
                    const Icon(Icons.zoom_in_rounded),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
                    ),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context, picture),
                        child: const Text('Готово'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
