import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/features/home_tips/home_tip.dart';
import 'package:zeon/features/home_tips/home_tip_provider.dart';
import 'package:zeon/utils/uri_utils.dart';

class HomeTipCard extends ConsumerWidget {
  const HomeTipCard({
    super.key,
    required this.content,
    this.maxHeight = double.infinity,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 12),
  });
  final HomeTipContent content;
  final double maxHeight;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: padding,
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: ((maxHeight - 12) * content.tip.aspectRatio).clamp(0, 520)),
          child: Material(
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Semantics(
                  label: content.tip.title,
                  button: true,
                  child: InkWell(
                    key: const ValueKey('home_tip_open'),
                    onTap: () => UriUtils.tryLaunch(content.tip.targetUrl),
                    child: AspectRatio(
                      aspectRatio: content.tip.aspectRatio,
                      child: Image.memory(
                        content.bytes,
                        fit: BoxFit.contain,
                        excludeFromSemantics: true,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: IconButton(
                    key: const ValueKey('home_tip_dismiss'),
                    tooltip: 'Скрыть подсказку',
                    style: IconButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: const Color(0xCC121316),
                      minimumSize: const Size(48, 48),
                    ),
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => ref.read(homeTipProvider.notifier).dismiss(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
