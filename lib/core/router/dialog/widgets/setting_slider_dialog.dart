import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/constants.dart';
import 'package:zeon/core/router/dialog/widgets/zeon_dialog.dart';
import 'package:zeon/utils/utils.dart';

class SettingsSliderDialog extends HookConsumerWidget with PresLogger {
  const SettingsSliderDialog({
    super.key,
    required this.title,
    required this.initialValue,
    this.onReset,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.labelGen,
  });

  final String title;
  final double initialValue;
  final VoidCallback? onReset;
  final double min;
  final double max;
  final int? divisions;
  final String Function(double value)? labelGen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final localizations = MaterialLocalizations.of(context);

    final sliderValue = useState(initialValue.clamp(min, max));
    final sliderFocusNode = useFocusNode(
      onKeyEvent: (node, event) {
        if (KeyboardConst.verticalArrows.contains(event.logicalKey) && event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
            node.nextFocus();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
    );

    return ZeonDialog(
      title: Text(title),
      icon: const Icon(Icons.timer_outlined),
      content: Container(
        padding: const EdgeInsets.fromLTRB(12, 24, 12, 16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              labelGen?.call(sliderValue.value) ?? sliderValue.value.toStringAsFixed(0),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 34, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 14),
            Slider(
              focusNode: sliderFocusNode,
              value: sliderValue.value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: (value) => sliderValue.value = value,
              label: labelGen?.call(sliderValue.value),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(child: Text(labelGen?.call(min) ?? '$min', style: const TextStyle(fontSize: 14))),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    labelGen?.call(max) ?? '$max',
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        if (onReset != null)
          TextButton(
            onPressed: () {
              onReset!();
              context.pop();
            },
            child: Text(t.common.reset),
          ),
        TextButton(onPressed: () => context.pop(), child: Text(localizations.cancelButtonLabel.toUpperCase())),
        TextButton(
          onPressed: () => context.pop(sliderValue.value),
          child: Text(localizations.okButtonLabel.toUpperCase()),
        ),
      ],
    );
  }
}
