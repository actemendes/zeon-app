import 'dart:typed_data';
import 'dart:ui' as ui;

/// Decode only a bounded thumbnail and persist normalized PNG, not picker paths.
Future<Uint8List> normalizeButtonImage(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > 15 * 1024 * 1024) throw const FormatException('Image size');
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width * descriptor.height > 40000000) throw const FormatException('Image dimensions');
      final factor = 768 / (descriptor.width > descriptor.height ? descriptor.width : descriptor.height);
      final codec = await descriptor.instantiateCodec(
        targetWidth: factor < 1 ? (descriptor.width * factor).round().clamp(1, 768) : descriptor.width,
        targetHeight: factor < 1 ? (descriptor.height * factor).round().clamp(1, 768) : descriptor.height,
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          return (await frame.image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}
