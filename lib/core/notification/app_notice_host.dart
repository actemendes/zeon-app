import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:zeon/core/localization/translation_context.dart';
import 'package:zeon/core/notification/app_notice.dart';

class AppNoticeHost extends StatefulWidget {
  const AppNoticeHost({super.key, required this.child, this.controller});

  final Widget child;
  final AppNoticeController? controller;

  @override
  State<AppNoticeHost> createState() => _AppNoticeHostState();
}

class _AppNoticeHostState extends State<AppNoticeHost> with WidgetsBindingObserver {
  AppNoticeController get controller => widget.controller ?? appNoticeController;

  @override
  void initState() {
    super.initState();
    controller.attach();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null) didChangeAppLifecycleState(state);
  }

  @override
  void didUpdateWidget(AppNoticeHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? appNoticeController).detach();
      controller.attach();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    controller.pause(AppNoticePause.background, paused: state != AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom > 0;
    final bottom =
        math.max(media.viewInsets.bottom, media.viewPadding.bottom) +
        (keyboard
            ? 12
            : media.size.width < 600
            ? 96
            : 24);
    final reduced = media.disableAnimations || media.accessibleNavigation;
    final duration = reduced ? Duration.zero : const Duration(milliseconds: 280);
    return Overlay.wrap(
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                media.viewPadding.left + 16,
                media.viewPadding.top + 12,
                media.viewPadding.right + 16,
                bottom,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) => Align(
                  alignment: Alignment.bottomCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 420, maxHeight: math.min(340, constraints.maxHeight)),
                    child: ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) {
                        final entries = controller.entries;
                        final front = entries.firstOrNull;
                        return MouseRegion(
                          onEnter: (_) => controller.pause(AppNoticePause.hover, paused: true),
                          onExit: (_) => controller.pause(AppNoticePause.hover, paused: false),
                          child: Focus(
                            canRequestFocus: false,
                            onFocusChange: (focused) => controller.pause(AppNoticePause.focus, paused: focused),
                            child: _NoticeSize(
                              duration: duration,
                              child: Padding(
                                padding: EdgeInsets.only(top: front == null ? 0 : 24),
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  alignment: Alignment.bottomCenter,
                                  children: [
                                    for (var depth = entries.length - 1; depth > 0; depth--)
                                      Positioned.fill(
                                        child: IgnorePointer(
                                          child: ExcludeSemantics(
                                            child: Transform.translate(
                                              offset: Offset(0, -12.0 * depth),
                                              child: Transform.scale(
                                                scale: 1 - .05 * depth,
                                                alignment: Alignment.topCenter,
                                                child: Opacity(
                                                  opacity: 1 - .16 * depth,
                                                  child: DecoratedBox(
                                                    decoration: _decoration(Theme.of(context).colorScheme),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    AnimatedSwitcher(
                                      duration: duration,
                                      switchInCurve: Curves.easeOutCubic,
                                      switchOutCurve: Curves.easeInCubic,
                                      layoutBuilder: (current, previous) => Stack(
                                        alignment: Alignment.bottomCenter,
                                        children: [
                                          // Outgoing cards must retain their own size until
                                          // the fade completes, including the last card.
                                          for (final outgoing in previous)
                                            IgnorePointer(child: ExcludeSemantics(child: outgoing)),
                                          if (current != null) current,
                                        ],
                                      ),
                                      transitionBuilder: (child, animation) => AnimatedBuilder(
                                        animation: animation,
                                        child: child,
                                        builder: (context, child) {
                                          final outgoing = animation.status == AnimationStatus.reverse;
                                          final progress = animation.value;
                                          return Opacity(
                                            opacity: progress,
                                            child: Transform.translate(
                                              offset: Offset(0, (outgoing ? -12 : 64) * (1 - progress)),
                                              child: Transform.scale(
                                                scale: outgoing ? .95 + .05 * progress : 1,
                                                alignment: Alignment.topCenter,
                                                child: child,
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                      child: front == null
                                          ? const SizedBox.shrink()
                                          : _SwipeNotice(
                                              key: ValueKey(front.id),
                                              onDismiss: () => controller.dismiss(front.id),
                                              child: AppNoticeCard(
                                                entry: front,
                                                onTap: () => controller.activate(front.id),
                                                onClose: () => controller.dismiss(front.id),
                                              ),
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// A zero-duration AnimatedSize can notify its layout listener during layout.
// Reduced motion must skip the size animation entirely.
class _NoticeSize extends StatelessWidget {
  const _NoticeSize({required this.duration, required this.child});

  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) => duration == Duration.zero
      ? child
      : AnimatedSize(duration: duration, alignment: Alignment.bottomCenter, curve: Curves.easeOutCubic, child: child);
}

// Unlike Dismissible, this can remain in AnimatedSwitcher's outgoing layer.
class _SwipeNotice extends StatefulWidget {
  const _SwipeNotice({super.key, required this.child, required this.onDismiss});
  final Widget child;
  final VoidCallback onDismiss;

  @override
  State<_SwipeNotice> createState() => _SwipeNoticeState();
}

class _SwipeNoticeState extends State<_SwipeNotice> {
  double _offset = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onHorizontalDragUpdate: (details) => setState(() => _offset += details.delta.dx),
    onHorizontalDragCancel: () => setState(() => _offset = 0),
    onHorizontalDragEnd: (details) {
      final dismiss = _offset.abs() >= 64 || details.velocity.pixelsPerSecond.dx.abs() >= 700;
      setState(() => _offset = 0);
      if (dismiss) widget.onDismiss();
    },
    child: Transform.translate(offset: Offset(_offset, 0), child: widget.child),
  );
}

BoxDecoration _decoration(ColorScheme scheme) => BoxDecoration(
  color: Color.alphaBlend(
    Colors.white.withValues(alpha: scheme.brightness == Brightness.light ? .72 : .025),
    scheme.surfaceContainerHigh,
  ),
  borderRadius: BorderRadius.circular(20),
  border: Border.all(color: scheme.onSurface.withValues(alpha: .12)),
  boxShadow: [
    BoxShadow(
      color: Colors.black.withValues(alpha: scheme.brightness == Brightness.light ? .12 : .28),
      blurRadius: 24,
      offset: const Offset(0, 8),
    ),
  ],
);

class AppNoticeCard extends StatelessWidget {
  const AppNoticeCard({super.key, required this.entry, required this.onTap, required this.onClose});

  final AppNoticeEntry entry;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final notice = entry.notice;
    final scheme = Theme.of(context).colorScheme;
    final remote = notice.kind == AppNoticeKind.remote;
    final accent = switch (notice.kind) {
      AppNoticeKind.error => scheme.error,
      AppNoticeKind.info => scheme.onSurface,
      _ => scheme.brightness == Brightness.light ? const Color(0xFF247D36) : scheme.primary,
    };
    final icon =
        notice.icon ??
        switch (notice.kind) {
          AppNoticeKind.info => Icons.info_outline_rounded,
          AppNoticeKind.success => Icons.check_rounded,
          AppNoticeKind.error => Icons.error_outline_rounded,
          AppNoticeKind.remote => Icons.notifications_none_rounded,
        };
    return Semantics(
      container: true,
      liveRegion: true,
      child: DecoratedBox(
        decoration: _decoration(scheme),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 92),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 4, 16),
                  child: Row(
                    crossAxisAlignment: remote ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Icon(icon, color: accent, size: 24),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    notice.title,
                                    maxLines: remote ? 2 : 4,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 16,
                                      height: 1.3,
                                      fontWeight: FontWeight.w600,
                                      color: scheme.onSurface,
                                    ),
                                  ),
                                ),
                                if (entry.count > 1) ...[
                                  const SizedBox(width: 5),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: accent.withValues(alpha: .10),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '×${entry.count}',
                                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: accent),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (notice.body?.isNotEmpty == true) ...[
                              const SizedBox(height: 6),
                              Text(
                                notice.body!,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 14, height: 1.45, color: scheme.onSurfaceVariant),
                              ),
                            ],
                            if (notice.hasAction) ...[
                              const SizedBox(height: 8),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    context.translations.common.open,
                                    style: TextStyle(color: accent, fontSize: 16, fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(width: 5),
                                  Icon(Icons.arrow_forward_rounded, color: accent, size: 14),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: onClose,
                        tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                        icon: Icon(Icons.close_rounded, size: 17, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
