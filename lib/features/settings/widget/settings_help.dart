import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/features/settings/widget/settings_help_painter.dart';

/// Root modal covers the shell navigation too; its target never changes a value.
Future<void> showSettingsHelp(
  BuildContext context, {
  required String title,
  required String message,
  Future<void> Function()? onLearned,
}) async {
  final container = ProviderScope.containerOf(context);
  await showGeneralDialog<void>(
    context: context,
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (_, _, _) => UncontrolledProviderScope(
      container: container,
      child: _SettingsHelpOverlay(anchor: context, title: title, message: message, onLearned: onLearned),
    ),
  );
}

/// Placed on the actual Routing row. Hidden shell branches must not start a tour.
class SettingsHelpOnboarding extends ConsumerStatefulWidget {
  const SettingsHelpOnboarding({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<SettingsHelpOnboarding> createState() => _SettingsHelpOnboardingState();
}

class _SettingsHelpOnboardingState extends ConsumerState<SettingsHelpOnboarding> {
  bool _scheduled = false;
  bool _showing = false;

  void _schedule() {
    if (_scheduled || _showing || ref.read(Preferences.settingsHelpLearned)) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _scheduled = false;
      if (!mounted ||
          !TickerMode.of(context) ||
          ModalRoute.of(context)?.isCurrent != true ||
          ref.read(Preferences.settingsHelpLearned)) {
        return;
      }
      _showing = true;
      await Scrollable.ensureVisible(context, alignment: .15);
      if (!mounted || !TickerMode.of(context) || ModalRoute.of(context)?.isCurrent != true) {
        _showing = false;
        return;
      }
      final t = ref.read(translationsProvider).requireValue;
      await showSettingsHelp(
        context,
        title: t.pages.settings.routing.title,
        message: t.settingsHelp.routing,
        onLearned: () => ref.read(Preferences.settingsHelpLearned.notifier).update(true),
      );
      _showing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Register dependencies even when this branch has already been built offstage.
    TickerMode.of(context);
    ModalRoute.of(context);
    ref.watch(Preferences.settingsHelpLearned);
    _schedule();
    return widget.child;
  }
}

class _SettingsHelpOverlay extends ConsumerStatefulWidget {
  const _SettingsHelpOverlay({required this.anchor, required this.title, required this.message, this.onLearned});
  final BuildContext anchor;
  final String title;
  final String message;
  final Future<void> Function()? onLearned;
  @override
  ConsumerState<_SettingsHelpOverlay> createState() => _SettingsHelpOverlayState();
}

class _SettingsHelpOverlayState extends ConsumerState<_SettingsHelpOverlay>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _surfaceKey = GlobalKey();
  late final AnimationController _hand;
  late bool _teaching = widget.onLearned != null;
  bool _saving = false;
  bool _measurementQueued = false;
  bool _revealAttempted = false;
  Rect? _target;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hand = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))
      ..addListener(_measureAfterLayout);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _revealAttempted = false;
    _measureAfterLayout();
  }

  @override
  void didChangeMetrics() {
    _revealAttempted = false;
    _measureAfterLayout();
  }

  void _measureAfterLayout() {
    if (_measurementQueued) return;
    _measurementQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _measurementQueued = false;
      if (!mounted) return;
      final target = widget.anchor.mounted ? widget.anchor.findRenderObject() : null;
      final surface = _surfaceKey.currentContext?.findRenderObject();
      if (target is RenderBox && target.attached && target.hasSize && surface is RenderBox && surface.hasSize) {
        final rect = surface.globalToLocal(target.localToGlobal(Offset.zero)) & target.size;
        // Resizing can strand a scrollable row below the viewport while the
        // modal blocks scrolling. Reveal the real row before measuring again.
        final safe = MediaQuery.paddingOf(context);
        final viewport = Rect.fromLTRB(8, safe.top + 8, surface.size.width - 8, surface.size.height - safe.bottom - 8);
        if (!_revealAttempted && rect.intersect(viewport).height < math.min(48, rect.height)) {
          _revealAttempted = true;
          await Scrollable.ensureVisible(widget.anchor, alignment: .15);
          if (!mounted || !target.attached || !surface.attached) return;
          // jumpTo invalidates viewport layout. Measure its completed frame,
          // including when reduced motion leaves the hand ticker stopped.
          _measureAfterLayout();
          WidgetsBinding.instance.scheduleFrame();
          return;
        }
        if (rect != _target) setState(() => _target = rect);
      } else {
        // A deep link can remove the underlying route while its modal is open.
        Navigator.of(context).pop();
      }
    });
  }

  Future<void> _learn() async {
    if (!_teaching || _saving) return;
    _saving = true;
    try {
      await widget.onLearned!();
    } finally {
      // A storage failure must not trap the user. A future launch may teach again.
      if (mounted) {
        setState(() {
          _teaching = false;
          _saving = false;
        });
      }
    }
  }

  void _close() {
    if (!_teaching) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hand.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(translationsProvider).requireValue;
    final reduced = ref.watch(Preferences.lowPowerMode) || MediaQuery.disableAnimationsOf(context);
    if (_teaching && !reduced) {
      if (!_hand.isAnimating) _hand.repeat();
    } else {
      _hand.stop();
    }
    return PopScope(
      canPop: !_teaching,
      child: Material(
        color: Colors.transparent,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            final safe = MediaQuery.paddingOf(context);
            final viewport = Rect.fromLTRB(8, safe.top + 8, size.width - 8, size.height - safe.bottom - 8);
            final visibleTarget = _target != null && _target!.overlaps(viewport);
            // Keep the card reachable even during the frame that repositions
            // an offscreen target; never lay out a negative intersection.
            final rect = visibleTarget
                ? _target!.intersect(viewport)
                : Rect.fromLTWH(16, safe.top + 16, size.width - 32, 0);
            final availableBelow = size.height - safe.bottom - rect.bottom - 24;
            final availableAbove = rect.top - safe.top - 24;
            final below = availableBelow >= availableAbove;
            final available = math.max(100.0, below ? availableBelow : availableAbove);
            final handGap = _teaching && below && available > 350 ? 88.0 : 0.0;
            final width = math.min(380.0, size.width - 32);
            final left = (rect.center.dx - width / 2).clamp(16.0, math.max(16.0, size.width - width - 16)).toDouble();
            final card = _HelpCard(
              title: _teaching ? t.settingsHelp.learn : widget.title,
              message: _teaching ? t.settingsHelp.tryRouting : widget.message,
              label: t.settingsHelp.label,
              teaching: _teaching,
              closeLabel: t.common.close,
              onClose: _close,
            );
            return Stack(
              key: _surfaceKey,
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _close,
                    child: CustomPaint(painter: SettingsSpotlightPainter(rect, _teaching)),
                  ),
                ),
                if (visibleTarget)
                  Positioned.fromRect(
                    rect: rect,
                    child: FocusableActionDetector(
                      autofocus: _teaching,
                      shortcuts: const {
                        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
                      },
                      actions: {
                        ActivateIntent: CallbackAction<ActivateIntent>(
                          onInvoke: (_) {
                            if (_teaching) _learn();
                            return null;
                          },
                        ),
                      },
                      child: Semantics(
                        button: _teaching,
                        label: _teaching ? '${widget.title}. ${t.settingsHelp.learn}' : widget.title,
                        onLongPress: _teaching ? _learn : null,
                        // Screen readers use their activation gesture for the same lesson.
                        onTap: _teaching ? _learn : null,
                        child: GestureDetector(
                          key: const ValueKey('settings-help-target'),
                          excludeFromSemantics: true,
                          behavior: HitTestBehavior.opaque,
                          onTap: () {},
                          onLongPress: _teaching ? _learn : null,
                        ),
                      ),
                    ),
                  ),
                if (_teaching && visibleTarget)
                  Positioned(
                    left: (rect.right - 112).clamp(8.0, size.width - 104),
                    top: handGap > 0 ? rect.bottom - 25 : rect.top - 10,
                    width: 104,
                    height: 115,
                    child: IgnorePointer(
                      child: ExcludeSemantics(
                        child: AnimatedBuilder(
                          animation: _hand,
                          builder: (_, _) => CustomPaint(painter: SettingsHandPainter(reduced ? .6 : _hand.value)),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: left,
                  width: width,
                  top: below ? rect.bottom + 12 + handGap : null,
                  bottom: below ? null : size.height - rect.top + 12,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: math.max(80, available - handGap)),
                    child: card,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _HelpCard extends StatelessWidget {
  const _HelpCard({
    required this.title,
    required this.message,
    required this.label,
    required this.teaching,
    required this.closeLabel,
    required this.onClose,
  });
  final String title;
  final String message;
  final String label;
  final String closeLabel;
  final bool teaching;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Material(
    key: const ValueKey('settings-help-card'),
    color: const Color(0xFF171C1B),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(22),
      side: const BorderSide(color: Color(0xFF39403C)),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 20, end: 6, top: 6),
          child: Row(
            children: [
              Icon(
                teaching ? Icons.touch_app_outlined : Icons.info_outline_rounded,
                color: const Color(0xFF3CE74F),
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontFamily: 'Montserrat',
                    color: Color(0xFF3CE74F),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!teaching)
                IconButton(
                  tooltip: closeLabel,
                  key: const ValueKey('settings-help-close'),
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded, size: 22, color: Color(0xFFB1B8C2)),
                )
              else
                const SizedBox(height: 38),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: 'Montserrat',
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  style: const TextStyle(
                    fontFamily: 'Montserrat',
                    color: Color(0xFFCDD4D2),
                    fontSize: 14,
                    height: 1.55,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
