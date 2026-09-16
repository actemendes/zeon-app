import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'active_breakpoint_notifier.g.dart';

@Riverpod(keepAlive: true)
class ActiveBreakpointNotifier extends _$ActiveBreakpointNotifier {
  @override
  Breakpoints? build() {
    return null;
  }

  void update(Breakpoints breakpoint) {
    if (breakpoint == state) return;
    state = breakpoint;
  }
}

@riverpod
bool? isMobileBreakpoint(Ref ref) {
  final breakpoint = ref.watch(activeBreakpointNotifierProvider);
  if (breakpoint == null) return null;
  return breakpoint == Breakpoints.mobile;
}

class Breakpoint {
  static const sMobile = 0.0;
  static const eMobile = 600.0;
  static const sTable = 601.0;
  static const eTable = 840.0;
  static const sDesktop = 841.0;
  static const eDesktop = double.infinity;
  static const compactHeight = 500.0;

  Breakpoint(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    _width = size.width;
    _height = size.height;
    if (_width < eMobile) {
      activeBreakpoint = Breakpoints.mobile;
    } else if (_width < eTable) {
      activeBreakpoint = Breakpoints.tablet;
    } else {
      activeBreakpoint = Breakpoints.desktop;
    }
  }

  late Breakpoints activeBreakpoint;
  late double _width;
  late double _height;

  bool isMobile() => activeBreakpoint == Breakpoints.mobile;
  bool isTablet() => activeBreakpoint == Breakpoints.tablet;
  bool isDesktop() => activeBreakpoint == Breakpoints.desktop;

  // Keep routing based on width; short windows only change presentation.
  bool isCompactHeight() => !isMobile() && _height < compactHeight;

  @override
  String toString() {
    return 'Breakpoint{name: ${activeBreakpoint.name}, width: $_width}';
  }
}

enum Breakpoints { mobile, tablet, desktop }
