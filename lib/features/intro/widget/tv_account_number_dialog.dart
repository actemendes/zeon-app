import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/dialog/widgets/zeon_dialog.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/core/widget/keyboard_focus_outline.dart';

/// Account entry for a TV remote, without opening the software keyboard.
/// The number is always a string so leading zeroes and long codes survive.
class TvAccountNumberDialog extends HookConsumerWidget {
  const TvAccountNumberDialog({
    super.key,
    required this.controller,
    required this.isSubmitting,
    required this.onSubmit,
    required this.onUseLink,
    this.errorText,
  });

  final TextEditingController controller;
  final bool isSubmitting;
  final VoidCallback? onSubmit;
  final VoidCallback onUseLink;
  final String? errorText;

  static final _digits = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.digit0: '0',
    LogicalKeyboardKey.digit1: '1',
    LogicalKeyboardKey.digit2: '2',
    LogicalKeyboardKey.digit3: '3',
    LogicalKeyboardKey.digit4: '4',
    LogicalKeyboardKey.digit5: '5',
    LogicalKeyboardKey.digit6: '6',
    LogicalKeyboardKey.digit7: '7',
    LogicalKeyboardKey.digit8: '8',
    LogicalKeyboardKey.digit9: '9',
    LogicalKeyboardKey.numpad0: '0',
    LogicalKeyboardKey.numpad1: '1',
    LogicalKeyboardKey.numpad2: '2',
    LogicalKeyboardKey.numpad3: '3',
    LogicalKeyboardKey.numpad4: '4',
    LogicalKeyboardKey.numpad5: '5',
    LogicalKeyboardKey.numpad6: '6',
    LogicalKeyboardKey.numpad7: '7',
    LogicalKeyboardKey.numpad8: '8',
    LogicalKeyboardKey.numpad9: '9',
  };

  void _setNumber(String value) {
    if (isSubmitting) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _appendDigit(String digit) => _setNumber('${controller.text}$digit');

  void _deleteDigit() {
    final value = controller.text;
    if (value.isNotEmpty) _setNumber(value.substring(0, value.length - 1));
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final digit = _digits[event.logicalKey];
    if (digit != null || event.logicalKey == LogicalKeyboardKey.backspace) {
      // One physical press edits once. Holding a remote key must not insert or
      // erase a run of digits, and key-up must not reach another text control.
      if (event is KeyDownEvent && !isSubmitting) {
        if (digit != null) {
          _appendDigit(digit);
        } else {
          _deleteDigit();
        }
      }
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent &&
        const [
          LogicalKeyboardKey.select,
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.numpadEnter,
          LogicalKeyboardKey.space,
        ].contains(event.logicalKey)) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    useListenable(controller);

    Widget keypadButton({
      required String keyName,
      required Widget child,
      required VoidCallback onPressed,
      bool autofocus = false,
    }) {
      return Expanded(
        child: TextButton(
          key: ValueKey(keyName),
          autofocus: autofocus,
          onPressed: isSubmitting ? null : onPressed,
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: EdgeInsets.zero,
            backgroundColor: colors.surface,
            foregroundColor: colors.onSurface,
            textStyle: theme.textTheme.titleLarge?.copyWith(fontSize: 24, fontWeight: FontWeight.w600),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ).copyWith(backgroundBuilder: KeyboardFocusOutline.buttonBuilder),
          child: child,
        ),
      );
    }

    Widget digitButton(String digit) => keypadButton(
      keyName: 'tv-account-digit-$digit',
      autofocus: digit == '1',
      onPressed: () => _appendDigit(digit),
      child: Text(digit),
    );

    final keypad = Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var row = 0; row < 3; row++) ...[
            if (row > 0) const SizedBox(height: 8),
            Row(
              children: [
                for (var column = 0; column < 3; column++) ...[
                  if (column > 0) const SizedBox(width: 8),
                  digitButton('${row * 3 + column + 1}'),
                ],
              ],
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              keypadButton(
                keyName: 'tv-account-clear',
                onPressed: () => _setNumber(''),
                child: Icon(Icons.clear_all_rounded, semanticLabel: t.intro.tvAccountNumberClear),
              ),
              const SizedBox(width: 8),
              digitButton('0'),
              const SizedBox(width: 8),
              keypadButton(
                keyName: 'tv-account-backspace',
                onPressed: _deleteDigit,
                child: Icon(Icons.backspace_outlined, semanticLabel: t.intro.tvAccountNumberDelete),
              ),
            ],
          ),
        ],
      ),
    );

    final controls = SizedBox(
      width: 296,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          keypad,
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey(UiNames.buttonIntroBindSubmit),
            onPressed: isSubmitting ? null : onSubmit,
            style: FilledButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              backgroundColor: colors.primary,
              foregroundColor: colors.onPrimary,
              textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ).copyWith(backgroundBuilder: KeyboardFocusOutline.buttonBuilder),
            child: isSubmitting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(t.pages.profileDetails.menu.bindAccount, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const ValueKey('tv-account-use-link'),
            onPressed: isSubmitting ? null : onUseLink,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              backgroundColor: colors.surface,
              foregroundColor: colors.onSurface,
            ).copyWith(backgroundBuilder: KeyboardFocusOutline.buttonBuilder),
            child: Text(t.intro.tvAccountNumberUseLink, textAlign: TextAlign.center),
          ),
        ],
      ),
    );

    final explanation = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t.intro.tvAccountNumberTitle,
          style: theme.textTheme.titleLarge?.copyWith(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: colors.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          t.intro.tvAccountNumberDescription,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.5, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        Semantics(
          label: t.intro.tvAccountNumberLabel,
          value: controller.text,
          liveRegion: true,
          child: ExcludeSemantics(
            child: Container(
              key: const ValueKey('tv-account-number-display'),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: errorText == null ? colors.outlineVariant : colors.error),
              ),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Text(
                    controller.text.isEmpty ? '…' : controller.text,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: controller.text.isEmpty ? colors.onSurfaceVariant : colors.onSurface,
                      fontSize: 30,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (errorText != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              errorText!,
              key: const ValueKey('tv-account-number-error'),
              style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
            ),
          ),
        ],
      ],
    );

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleKey,
      child: FocusTraversalGroup(
        child: ZeonDialog(
          key: const ValueKey('tv-account-number-dialog'),
          canDismiss: !isSubmitting,
          maxWidth: 760,
          title: Text(t.intro.alreadyHaveAccount),
          icon: const Icon(Icons.person_outline_rounded),
          content: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 560) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    explanation,
                    const SizedBox(height: 20),
                    Center(child: controls),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: explanation),
                  const SizedBox(width: 32),
                  controls,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
