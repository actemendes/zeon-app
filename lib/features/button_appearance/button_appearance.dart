import 'package:flutter/material.dart';

const zeonGreen = Color(0xFF3CE74F);
const zeonLime = Color(0xFFBFDD71);

enum ButtonPhase { idle, connecting, connected }

enum ButtonPreset { standard, anime, kawaii, custom }

extension PhaseLabel on ButtonPhase {
  String get label => switch (this) {
    ButtonPhase.idle => 'Выключено',
    ButtonPhase.connecting => 'Подключение',
    ButtonPhase.connected => 'Подключено',
  };
  String get action => switch (this) {
    ButtonPhase.idle => 'Подключиться',
    ButtonPhase.connecting => 'Отменить подключение',
    ButtonPhase.connected => 'Отключиться',
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
  const ButtonAppearance({this.preset = ButtonPreset.standard, this.pictures = const {}, this.name = 'Моя кнопка'});
  final ButtonPreset preset;
  final Map<ButtonPhase, ButtonPicture> pictures;
  final String name;
  bool get complete => ButtonPhase.values.every(pictures.containsKey);
  ButtonPicture? pictureFor(ButtonPhase phase) => switch (preset) {
    ButtonPreset.standard => null,
    ButtonPreset.anime => ButtonPicture(AssetImage('assets/images/button_presets/anime-${phase.name}.png')),
    ButtonPreset.kawaii => ButtonPicture(AssetImage('assets/images/button_presets/kawaii-${phase.name}.png')),
    ButtonPreset.custom => pictures[phase],
  };
}
