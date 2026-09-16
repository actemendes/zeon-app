import 'package:flutter/material.dart';
import 'package:zeon/core/router/go_router/helper/custom_transition.dart';

/// Keeps branch navigators mounted while animating the newly selected section.
class AnimatedBranchContainer extends StatefulWidget {
  const AnimatedBranchContainer({super.key, required this.currentIndex, required this.children});

  final int currentIndex;
  final List<Widget> children;

  @override
  State<AnimatedBranchContainer> createState() => _AnimatedBranchContainerState();
}

class _AnimatedBranchContainerState extends State<AnimatedBranchContainer> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: routeTransitionDuration, value: 1);
  late final _animation = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) _controller.value = 1;
  }

  @override
  void didUpdateWidget(covariant AnimatedBranchContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      if (_reduceMotion) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: FadeTransition(
      opacity: _animation,
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, child) => Transform.translate(offset: Offset(0, 12 * (1 - _animation.value)), child: child),
        child: IndexedStack(
          index: widget.currentIndex,
          children: [
            for (var index = 0; index < widget.children.length; index++)
              Offstage(
                offstage: index != widget.currentIndex,
                child: TickerMode(
                  enabled: index == widget.currentIndex,
                  child: ExcludeFocus(excluding: index != widget.currentIndex, child: widget.children[index]),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
