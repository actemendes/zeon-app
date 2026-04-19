import 'package:circle_flags/circle_flags.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/utils/ip_utils.dart';
import 'package:hiddify/gen/fonts.gen.dart';
import 'package:hiddify/utils/riverpod_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final _showIp = StateProvider.autoDispose((ref) {
  ref.disposeDelay(const Duration(seconds: 20));
  ref.listenSelf((previous, next) {
    if (previous == false && next == true) {
      ref.read(hapticServiceProvider.notifier).mediumImpact();
    }
  });
  return false;
});

class IPText extends HookConsumerWidget {
  const IPText({
    required this.ip,
    required this.onLongPress,
    this.constrained = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 2),
    this.textColor,
    super.key,
  });

  final String ip;
  final VoidCallback onLongPress;
  final bool constrained;
  final EdgeInsetsGeometry padding;
  final Color? textColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final isVisible = ref.watch(_showIp);
    final textTheme = Theme.of(context).textTheme;
    final ipStyle = (constrained ? textTheme.labelMedium : textTheme.labelLarge)?.copyWith(
      fontFamily: FontFamily.emoji,
      color: textColor,
    );

    return Semantics(
      label: t.pages.proxies.ipInfo.address,
      child: InkWell(
        onTap: () {
          ref.read(_showIp.notifier).state = !isVisible;
        },
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: padding,
          child: AnimatedCrossFade(
            firstChild: Text(ip, style: ipStyle, textDirection: TextDirection.ltr, overflow: TextOverflow.ellipsis),
            secondChild: Padding(
              padding: constrained ? EdgeInsets.zero : const EdgeInsetsDirectional.only(end: 48),
              child: Text(
                obscureIp(ip),
                semanticsLabel: t.common.hidden,
                style: ipStyle,
                textDirection: TextDirection.ltr,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            crossFadeState: isVisible ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            duration: const Duration(milliseconds: 200),
          ),
        ),
      ),
    );
  }
}

class UnknownIPText extends HookConsumerWidget {
  const UnknownIPText({
    required this.text,
    required this.onTap,
    this.constrained = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 2),
    this.textColor,
    super.key,
  });

  final String text;
  final VoidCallback onTap;
  final bool constrained;
  final EdgeInsetsGeometry padding;
  final Color? textColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final textTheme = Theme.of(context).textTheme;
    final style = (constrained ? textTheme.bodySmall : textTheme.labelMedium)?.copyWith(color: textColor);

    return Semantics(
      label: t.pages.proxies.ipInfo.address,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: padding,
          child: Text(text, style: style, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}

class IPCountryFlag extends HookConsumerWidget {
  const IPCountryFlag({required this.countryCode, this.size = 16, this.padding = EdgeInsets.zero, super.key});

  final String? countryCode;
  final double size;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    return Semantics(
      label: t.pages.proxies.ipInfo.country,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onLongPress: () {},
        child: Padding(
          padding: padding,
          child: (countryCode?.isEmpty ?? true)
              ? Icon(FluentIcons.question_circle_20_regular, size: size)
              : SizedBox(
                  width: size,
                  height: size,
                  child: CircleFlag(
                    // key: ValueKey(countryCode),
                    countryCode!.toLowerCase() == "ir" ? "ir-shir" : countryCode!,
                    size: size,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8), // Rounded effect
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
