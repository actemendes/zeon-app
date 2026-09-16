import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:zeon/core/widget/spaced_list_widget.dart';

typedef PresentableStat = ({Widget label, Widget data, String? semanticLabel});

class StatsCard extends StatelessWidget {
  const StatsCard({
    super.key,
    this.title,
    this.titleStyle,
    this.padding = const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
    this.labelStyle,
    this.dataStyle,
    required this.stats,
  });

  final String? title;
  final TextStyle? titleStyle;
  final EdgeInsets padding;
  final TextStyle? labelStyle;
  final TextStyle? dataStyle;
  final List<PresentableStat> stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLightTheme = theme.brightness == Brightness.light;
    final lightContentColor = isLightTheme ? theme.colorScheme.onSurface : null;

    final effectiveTitleStyle =
        titleStyle ??
        theme.textTheme.bodySmall?.copyWith(color: isLightTheme ? theme.colorScheme.onSurfaceVariant : null);
    final effectiveLabelStyle =
        labelStyle ??
        theme.textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: isLightTheme ? theme.colorScheme.onSurfaceVariant : null,
        );
    final effectiveDataStyle =
        dataStyle ??
        theme.textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: lightContentColor,
        );

    return Card(
      margin: EdgeInsets.zero,
      color: isLightTheme ? theme.colorScheme.surface : null,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[Text(title!, style: effectiveTitleStyle), const Gap(4)],
            ...stats
                .map((stat) {
                  Widget label = IconTheme.merge(
                    data: IconThemeData(size: 14, color: effectiveLabelStyle?.color),
                    child: DefaultTextStyle(
                      style: effectiveLabelStyle!,
                      overflow: TextOverflow.ellipsis,
                      child: stat.label,
                    ),
                  );
                  if (stat.semanticLabel != null) {
                    label = Tooltip(message: stat.semanticLabel, verticalOffset: 8, child: label);
                  }
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      label,
                      const Gap(2),
                      DefaultTextStyle(style: effectiveDataStyle!, overflow: TextOverflow.ellipsis, child: stat.data),
                    ],
                  );
                })
                .toList()
                .spaceBy(height: 2),
          ],
        ),
      ),
    );
  }
}
