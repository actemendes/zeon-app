import 'package:flutter/material.dart';
import 'package:zeon/gen/translations.g.dart';

const zeonGreen = Color(0xFF3CE74F);
const zeonLime = Color(0xFFBFDD71);

enum ButtonPhase { idle, connecting, connected }

enum ButtonPreset { standard, kawaii, custom }

extension PhaseLabel on ButtonPhase {
  String label(Translations t) => switch (this) {
    ButtonPhase.idle => t.buttonAppearance.idle,
    ButtonPhase.connecting => t.buttonAppearance.connecting,
    ButtonPhase.connected => t.buttonAppearance.connected,
  };
  String action(Translations t) => switch (this) {
    ButtonPhase.idle => t.buttonAppearance.connectAction,
    ButtonPhase.connecting => t.buttonAppearance.cancelAction,
    ButtonPhase.connected => t.buttonAppearance.disconnectAction,
  };
}

@immutable
class ButtonPicture {
  const ButtonPicture(this.image, {this.zoom = 1, this.alignment = Alignment.center});
  final ImageProvider image;
  final double zoom;
  final Alignment alignment;
}

@immutable
class ButtonAppearance {
  const ButtonAppearance({this.preset = ButtonPreset.standard, this.pictures = const {}, this.name = ''});
  final ButtonPreset preset;
  final Map<ButtonPhase, ButtonPicture> pictures;
  final String name;
  bool get complete => ButtonPhase.values.every(pictures.containsKey);
  ButtonPicture? pictureFor(ButtonPhase phase) => switch (preset) {
    ButtonPreset.standard => null,
    ButtonPreset.kawaii => ButtonPicture(AssetImage('assets/images/button_presets/kawaii-${phase.name}.png')),
    ButtonPreset.custom => pictures[phase],
  };
}
