import 'dart:math' as math;

import 'package:flutter/material.dart';

Future<T?> showZeonDialog<T>(BuildContext context, Widget child) {
  if (MediaQuery.sizeOf(context).width < 600) {
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .55),
      builder: (_) => child,
    );
  }
  return showDialog<T>(context: context, barrierColor: Colors.black.withValues(alpha: .55), builder: (_) => child);
}

/// A scrollable body with persistent actions, shared by settings and diagnostics.
class ZeonDialog extends StatelessWidget {
  const ZeonDialog({
    super.key,
    this.title,
    this.icon,
    this.content,
    this.actions,
    this.footer,
    this.primaryAction = true,
  });
  final Widget? title;
  final Widget? icon;
  final Widget? content;
  final Widget? footer;
  final List<Widget>? actions;
  final bool primaryAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final media = MediaQuery.of(context);
    final mobile = media.size.width < 600;
    final compact = media.size.width < 360 || media.textScaler.scale(1) > 1.2;
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none);
    final actionStyle = TextButton.styleFrom(
      minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      textStyle: const TextStyle(fontFamily: 'Montserrat', fontSize: 13, fontWeight: FontWeight.w600),
    );
    final contents = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 460,
        maxHeight: math.max(
          0,
          math.min(760, media.size.height - media.viewInsets.bottom - media.padding.vertical - (mobile ? 24 : 48)),
        ),
      ),
      child: Theme(
        data: theme.copyWith(
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: cs.surface,
            contentPadding: const EdgeInsets.all(18),
            border: border,
            enabledBorder: border,
            focusedBorder: border,
            errorBorder: border,
            focusedErrorBorder: border,
            disabledBorder: border,
          ),
          textButtonTheme: TextButtonThemeData(style: actionStyle),
        ),
        child: Material(
          color: cs.secondaryContainer,
          borderRadius: BorderRadius.circular(28),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final header = Row(
                  children: [
                    if (!compact) ...[
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(color: cs.surface, shape: BoxShape.circle),
                        child: IconTheme(
                          data: IconThemeData(size: 20, color: cs.onSurface),
                          child: icon ?? const Icon(Icons.tune_rounded),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: DefaultTextStyle(
                        style: TextStyle(
                          fontFamily: 'Unbounded',
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          height: 1.45,
                          color: cs.onSurface,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        child: title ?? const SizedBox.shrink(),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                      icon: Icon(Icons.close_rounded, size: 20, color: cs.onSurfaceVariant),
                    ),
                  ],
                );
                final body = DefaultTextStyle(
                  style: TextStyle(fontFamily: 'Montserrat', fontSize: 13, height: 1.65, color: cs.onSurfaceVariant),
                  child: content ?? const SizedBox.shrink(),
                );
                final buttons = footer ?? _DialogActions(actions: actions ?? const [], primaryAction: primaryAction);
                // With a keyboard or exceptionally short window the entire surface scrolls;
                // on normal screens only the content scrolls and actions remain visible.
                if (constraints.maxHeight < 300 * media.textScaler.scale(1)) {
                  return SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [header, const SizedBox(height: 22), body, const SizedBox(height: 24), buttons],
                    ),
                  );
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    const SizedBox(height: 22),
                    Flexible(child: SingleChildScrollView(child: body)),
                    if (footer != null || (actions?.isNotEmpty ?? false)) ...[const SizedBox(height: 24), buttons],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    if (ModalRoute.of(context) is ModalBottomSheetRoute) {
      return Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: SafeArea(
          top: false,
          child: Padding(padding: const EdgeInsets.all(12), child: contents),
        ),
      );
    }
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.all(mobile ? 12 : 24),
      alignment: mobile ? Alignment.bottomCenter : Alignment.center,
      child: contents,
    );
  }
}

class _DialogActions extends StatelessWidget {
  const _DialogActions({required this.actions, required this.primaryAction});
  final List<Widget> actions;
  final bool primaryAction;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget styled(int i) => TextButtonTheme(
      data: TextButtonThemeData(
        style: TextButtonTheme.of(context).style?.copyWith(
          backgroundColor: WidgetStatePropertyAll(primaryAction && i == actions.length - 1 ? cs.primary : cs.surface),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? cs.onSurface.withValues(alpha: .38)
                : primaryAction && i == actions.length - 1
                ? cs.onPrimary
                : cs.onSurface,
          ),
        ),
      ),
      child: actions[i],
    );
    if (actions.length > 2) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DialogActions(actions: actions.sublist(actions.length - 2), primaryAction: primaryAction),
          const SizedBox(height: 8),
          for (final action in actions.take(actions.length - 2)) action,
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 300 || MediaQuery.textScalerOf(context).scale(1) > 1.3) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < actions.length; i++) ...[if (i > 0) const SizedBox(height: 8), styled(i)],
            ],
          );
        }
        return Row(
          children: [
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) const SizedBox(width: 10),
              Expanded(child: styled(i)),
            ],
          ],
        );
      },
    );
  }
}

class DialogChoice extends StatelessWidget {
  const DialogChoice({super.key, required this.title, required this.selected, required this.onTap, this.leading});
  final String title;
  final bool selected;
  final VoidCallback onTap;
  final Widget? leading;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        selected: selected,
        child: Material(
          color: cs.surface,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 12)],
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(fontFamily: 'Montserrat', fontSize: 13, height: 1.5, color: cs.onSurface),
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (selected)
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
                      child: Icon(Icons.check_rounded, size: 16, color: cs.onPrimary),
                    )
                  else
                    Icon(Icons.circle_outlined, size: 22, color: cs.onSurfaceVariant.withValues(alpha: .6)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
