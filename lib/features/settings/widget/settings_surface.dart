import 'package:flutter/material.dart';

/// Shared, full-width settings composition. Each group keeps its own live controls.
class SettingsList extends StatelessWidget {
  const SettingsList({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  );
}

class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children, this.title});
  final List<Widget> children;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
              child: Text(
                title!,
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          Material(
            color: cs.secondaryContainer,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 54, right: 16),
                      child: Divider(height: 1, color: cs.onSurface.withValues(alpha: .07)),
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsHint extends StatelessWidget {
  const SettingsHint({super.key, required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontFamily: 'Montserrat', fontSize: 14, height: 1.6, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });
  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Opacity(
      opacity: enabled ? 1 : .42,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
          child: Row(
            children: [
              if (leading != null) ...[
                IconTheme(
                  data: IconThemeData(size: 22, color: cs.onSurfaceVariant),
                  child: leading!,
                ),
                const SizedBox(width: 16),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DefaultTextStyle(
                      style: TextStyle(
                        fontFamily: 'Montserrat',
                        fontSize: 16,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                      child: title,
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 5),
                      DefaultTextStyle(
                        style: TextStyle(
                          fontFamily: 'Montserrat',
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          height: 1.5,
                          color: cs.onSurfaceVariant,
                        ),
                        child: subtitle!,
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null || onTap != null) ...[
                const SizedBox(width: 12),
                IconTheme(
                  data: IconThemeData(size: 19, color: cs.onSurfaceVariant),
                  child: trailing ?? const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsSwitch extends StatelessWidget {
  const SettingsSwitch({
    super.key,
    required this.title,
    this.subtitle,
    this.secondary,
    required this.value,
    required this.onChanged,
  });
  final Widget title;
  final Widget? subtitle;
  final Widget? secondary;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => SettingsTile(
    title: title,
    subtitle: subtitle,
    leading: secondary,
    enabled: onChanged != null,
    onTap: onChanged == null ? null : () => onChanged!(!value),
    trailing: SizedBox(
      width: 46,
      height: 30,
      child: FittedBox(
        child: Switch.adaptive(
          value: value,
          onChanged: onChanged,
          trackOutlineWidth: const WidgetStatePropertyAll(0),
          trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
    ),
  );
}
