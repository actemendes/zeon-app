import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

enum TransitionType { slide, fade }

const routeTransitionDuration = Duration(milliseconds: 280);
const reverseRouteTransitionDuration = Duration(milliseconds: 220);

CustomTransitionPage<dynamic> customTransition(TransitionType transition, LocalKey pageKey, Widget child) =>
    CustomTransitionPage(
      key: pageKey,
      child: child,
      transitionDuration: routeTransitionDuration,
      reverseTransitionDuration: reverseRouteTransitionDuration,
      transitionsBuilder: (context, animation, _, child) => switch (transition) {
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
