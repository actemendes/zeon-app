import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/features/button_appearance/button_appearance.dart';

/// A single preference commit publishes a complete set of immutable local files.
class ButtonAppearanceRepository {
  ButtonAppearanceRepository(this.preferences, this.directory);
  static const preferenceKey = 'button_appearance_v1';
  final SharedPreferences preferences;
  final Directory directory;
  static final _ownedName = RegExp(r'^[a-f0-9]{64}\.png$');
  static bool _assetAllowed(String asset) => [
    for (final preset in ['anime', 'kawaii'])
      for (final phase in ButtonPhase.values) 'assets/images/button_presets/$preset-${phase.name}.png',
  ].contains(asset);

  Future<ButtonAppearance> load() async {
    try {
      final raw = preferences.getString(preferenceKey);
      if (raw == null) return const ButtonAppearance();
      final value = jsonDecode(raw) as Map<String, dynamic>;
      if (value['version'] != 1) return const ButtonAppearance();
      final preset = ButtonPreset.values.byName(value['preset'] as String);
      final pictures = <ButtonPhase, ButtonPicture>{};
      final slots = value['pictures'] as Map<String, dynamic>;
      for (final phase in ButtonPhase.values) {
        try {
          final slot = slots[phase.name] as Map<String, dynamic>?;
          if (slot == null) continue;
          final zoom = (slot['zoom'] as num).toDouble();
          final x = (slot['x'] as num).toDouble();
          final y = (slot['y'] as num).toDouble();
          if (!zoom.isFinite || zoom < 1 || zoom > 3 || !x.isFinite || x.abs() > 1 || !y.isFinite || y.abs() > 1) {
            continue;
          }
          final ImageProvider image;
          if (slot['asset'] is String && _assetAllowed(slot['asset'] as String)) {
            image = AssetImage(slot['asset'] as String);
          } else {
            final file = slot['file'] as String;
            if (!_ownedName.hasMatch(file)) continue;
            final local = File(p.join(directory.path, file));
            if (!await local.exists()) continue;
            image = FileImage(local);
          }
          pictures[phase] = ButtonPicture(image, zoom: zoom, alignment: Alignment(x, y));
        } catch (_) {
          /* A bad slot cannot prevent startup. */
        }
      }
      return ButtonAppearance(
        preset: preset == ButtonPreset.custom && pictures.length != 3 ? ButtonPreset.standard : preset,
        name: value['name'] is String
            ? (value['name'] as String).substring(0, (value['name'] as String).length.clamp(0, 32))
            : 'Моя кнопка',
        pictures: Map.unmodifiable(pictures),
      );
    } catch (_) {
      return const ButtonAppearance();
    }
  }

  Future<ButtonAppearance> save(ButtonAppearance appearance) async {
    if (appearance.preset == ButtonPreset.custom && (!appearance.complete || appearance.name.trim().isEmpty)) {
      throw const FormatException('Incomplete custom preset');
    }
    await directory.create(recursive: true);
    final slots = <String, Object>{};
    final saved = <ButtonPhase, ButtonPicture>{};
    for (final entry in appearance.pictures.entries) {
      final picture = entry.value;
      final image = picture.image;
      if (!picture.zoom.isFinite ||
          picture.zoom < 1 ||
          picture.zoom > 3 ||
          !picture.alignment.x.isFinite ||
          picture.alignment.x.abs() > 1 ||
          !picture.alignment.y.isFinite ||
          picture.alignment.y.abs() > 1) {
        throw const FormatException('Invalid crop');
      }
      final slot = <String, Object>{'zoom': picture.zoom, 'x': picture.alignment.x, 'y': picture.alignment.y};
      final ImageProvider persisted;
      if (image is AssetImage && _assetAllowed(image.assetName)) {
        slot['asset'] = image.assetName;
        persisted = image;
      } else {
        final bytes = switch (image) {
          MemoryImage() => image.bytes,
          FileImage()
              when p.equals(p.dirname(image.file.path), directory.path) &&
                  _ownedName.hasMatch(p.basename(image.file.path)) =>
            await image.file.readAsBytes(),
          _ => throw const FormatException('Unsupported image source'),
        };
        if (bytes.isEmpty || bytes.length > 15 * 1024 * 1024) throw const FormatException('Image size');
        final digest = await Sha256().hash(bytes);
        final name = '${digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}.png';
        final file = File(p.join(directory.path, name));
        if (!await file.exists()) {
          final staging = File('${file.path}.tmp');
          await staging.writeAsBytes(bytes, flush: true);
          await staging.rename(file.path);
        }
        slot['file'] = name;
        persisted = FileImage(file);
      }
      slots[entry.key.name] = slot;
      saved[entry.key] = ButtonPicture(persisted, zoom: picture.zoom, alignment: picture.alignment);
    }
    final encoded = jsonEncode({
      'version': 1,
      'preset': appearance.preset.name,
      'name': appearance.name.trim(),
      'pictures': slots,
    });
    if (!await preferences.setString(preferenceKey, encoded)) {
      throw const FileSystemException('Preference write failed');
    }
    // After publishing the new configuration, collect only files this store owns.
    final retained = slots.values.cast<Map<String, Object>>().map((s) => s['file']).whereType<String>().toSet();
    try {
      await for (final file in directory.list(followLinks: false)) {
        final name = p.basename(file.path);
        if (file is File && _ownedName.hasMatch(name) && !retained.contains(name)) await file.delete();
      }
    } catch (_) {
      /* Cleanup failure does not invalidate a committed selection. */
    }
    return ButtonAppearance(preset: appearance.preset, name: appearance.name.trim(), pictures: Map.unmodifiable(saved));
  }
}
