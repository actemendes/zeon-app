import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

enum TransitionType { slide, fade }

const routeTransitionDuration = Duration(milliseconds: 280);
const reverseRouteTransitionDuration = Duration(milliseconds: 220);

CustomTransitionPage<dynamic> customTransition(
  TransitionType transition,
  LocalKey pageKey,
  Widget child, {
  bool reduceMotion = false,
}) => _MotionAwareTransitionPage(
  key: pageKey,
  child: child,
  transitionDuration: reduceMotion ? Duration.zero : routeTransitionDuration,
  reverseTransitionDuration: reduceMotion ? Duration.zero : reverseRouteTransitionDuration,
  transitionsBuilder: (context, animation, _, child) =>
      reduceMotion || (MediaQuery.maybeOf(context)?.disableAnimations ?? false)
      ? child
      : switch (transition) {
          TransitionType.slide => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1.0, 0.0),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
            textDirection: Directionality.of(context),
            child: child,
          ),
          TransitionType.fade => FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic),
            child: child,
          ),
        },
);

class _MotionAwareTransitionPage extends CustomTransitionPage<dynamic> {
  const _MotionAwareTransitionPage({
    required super.key,
    required super.child,
    required super.transitionsBuilder,
    required super.transitionDuration,
    required super.reverseTransitionDuration,
  });

  @override
  Route<dynamic> createRoute(BuildContext context) => _MotionAwareTransitionRoute(this);
}

class _MotionAwareTransitionRoute extends PageRoute<dynamic> {
  _MotionAwareTransitionRoute(_MotionAwareTransitionPage page) : super(settings: page);

  _MotionAwareTransitionPage get _page => settings as _MotionAwareTransitionPage;

  @override
  Duration get transitionDuration => _page.transitionDuration;
  @override
  Duration get reverseTransitionDuration => _page.reverseTransitionDuration;
  @override
  bool get maintainState => true;
  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;

  @override
  bool didPop(dynamic result) {
    // Navigator preserves the route/controller when a page with the same key
    // changes. Apply live motion settings to that existing controller too.
    controller?.reverseDuration = reverseTransitionDuration;
    return super.didPop(result);
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      Semantics(scopesRoute: true, explicitChildNodes: true, child: _page.child);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _page.transitionsBuilder(context, animation, secondaryAnimation, child);
}
