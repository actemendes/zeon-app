import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';

/// Presentation only. Time can move dots, but cannot change the VPN state.
class WorldMapMotion extends ChangeNotifier {
  WorldMapMotion(this.state) {
    connected = state.isConnected ? 1 : 0;
    connecting = state.isStarting ? 1 : 0;
    speed = _targetSpeed;
  }

  MainVpnButtonState state;
  Offset? origin;
  bool reducedMotion = false;
  double seconds = 0;
  double phase = 0;
  double connected = 0;
  double connecting = 0;
  double speed = .42;
  double _emissionStart = 0;

  double get _targetSpeed => state.isConnected
      ? 1.3
      : state.isStarting
      ? 1.05
      : .42;

  void updateState(MainVpnButtonState next) {
    if (state == next) return;
    if ((next.isStarting && !state.isStarting) || (next.isConnected && !state.isConnected && !state.isStarting)) {
      _emissionStart = seconds;
    }
    state = next;
    if (reducedMotion) _settle();
    notifyListeners();
  }

  void updateReducedMotion(bool value) {
    if (reducedMotion == value) return;
    reducedMotion = value;
    if (value) _settle();
    notifyListeners();
  }

  void _settle() {
    connected = state.isConnected ? 1 : 0;
    connecting = state.isStarting ? 1 : 0;
    speed = _targetSpeed;
  }

  void updateOrigin(Offset value) {
    if (origin != null && (origin! - value).distance < .25) return;
    origin = value;
    notifyListeners();
  }

  void advance(double delta) {
    if (reducedMotion || delta <= 0) return;
    // A suspended/slow frame must not teleport the wave across the screen.
    final dt = delta.clamp(0.0, .1);
    final blend = 1 - math.exp(-dt / .45);
    connected += ((state.isConnected ? 1 : 0) - connected) * blend;
    connecting += ((state.isStarting ? 1 : 0) - connecting) * blend;
    speed += (_targetSpeed - speed) * blend;
    seconds += dt;
    phase += dt * speed;
    notifyListeners();
  }

  ({double scale, double tint}) sample(Offset position, Offset fallbackOrigin) {
    if (reducedMotion) return (scale: 1, tint: connected * .1);
    final ambient =
        .65 * math.sin(position.dx / 155 + position.dy / 220 - phase) +
        .35 * math.sin(position.dy / 130 - position.dx / 310 - phase * .7);
    final distance = (position - (origin ?? fallbackOrigin)).distance;
    // Nothing ahead of the first wave changes early: it travels out from the
    // measured button center at 230 logical pixels/second. Subsequent ripples
    // have smooth zero-amplitude ends, including the loop boundary.
    final localTime = seconds - _emissionStart - distance / 230;
    var pulse = 0.0;
    if (localTime > 0) {
      final beat = localTime % 2.8;
      if (beat < .95) pulse = math.pow(math.sin(math.pi * beat / .95), 2).toDouble();
    }
    // Size carries the wave even in the neutral palette. Blend toward the
    // crest radius instead of adding it, keeping neighboring dots separate.
    final breathingScale = .8 + .35 * ambient + .12 * connected * (ambient + 1) / 2;
    return (
      scale: breathingScale + (1.35 - breathingScale) * connecting * pulse,
      tint: (.08 + .1 * (ambient + 1) / 2) * connected + .24 * connecting * pulse,
    );
  }
}
