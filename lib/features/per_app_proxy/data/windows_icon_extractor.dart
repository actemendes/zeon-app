import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

typedef WindowsIconLoader = Uint8List? Function(String iconSource);

final class _ICONINFO extends Struct {
  @Int32()
  external int fIcon;

  @Uint32()
  external int xHotspot;

  @Uint32()
  external int yHotspot;

  @IntPtr()
  external int hbmMask;

  @IntPtr()
  external int hbmColor;
}

final class _BITMAP extends Struct {
  @Int32()
  external int bmType;

  @Int32()
  external int bmWidth;

  @Int32()
  external int bmHeight;

  @Int32()
  external int bmWidthBytes;

  @Uint16()
  external int bmPlanes;

  @Uint16()
  external int bmBitsPixel;

  @IntPtr()
  external int bmBits;
}

final class _BITMAPINFOHEADER extends Struct {
  @Uint32()
  external int biSize;

  @Int32()
  external int biWidth;

  @Int32()
  external int biHeight;

  @Uint16()
  external int biPlanes;

  @Uint16()
  external int biBitCount;

  @Uint32()
  external int biCompression;

  @Uint32()
  external int biSizeImage;

  @Int32()
  external int biXPelsPerMeter;

  @Int32()
  external int biYPelsPerMeter;

  @Uint32()
  external int biClrUsed;

  @Uint32()
  external int biClrImportant;

  @Uint32()
  external int bmiColors0;
}

final class _Win32IconApis {
  const _Win32IconApis({
    required this.privateExtractIconsW,
    required this.extractIconExW,
    required this.getIconInfo,
    required this.destroyIcon,
    required this.getObjectW,
    required this.createCompatibleDC,
    required this.deleteDC,
    required this.deleteObject,
    required this.getDIBits,
  });

  final int Function(
    Pointer<Utf16> szFileName,
    int nIconIndex,
    int cxIcon,
    int cyIcon,
    Pointer<IntPtr> phicon,
    Pointer<Uint32> piconid,
    int nIcons,
    int flags,
  )
  privateExtractIconsW;

  final int Function(
    Pointer<Utf16> lpszFile,
    int nIconIndex,
    Pointer<IntPtr> phiconLarge,
    Pointer<IntPtr> phiconSmall,
    int nIcons,
  )
  extractIconExW;

  final int Function(int hIcon, Pointer<_ICONINFO> piconinfo) getIconInfo;
  final int Function(int hIcon) destroyIcon;
  final int Function(int h, int c, Pointer<Void> pv) getObjectW;
  final int Function(int hdc) createCompatibleDC;
  final int Function(int hdc) deleteDC;
  final int Function(int ho) deleteObject;

  final int Function(
    int hdc,
    int hbmp,
    int uStartScan,
    int cScanLines,
    Pointer<Uint8> lpvBits,
    Pointer<_BITMAPINFOHEADER> lpbmi,
    int uUsage,
  )
  getDIBits;
}

class WindowsIconExtractor {
  WindowsIconExtractor._();

  static final Map<String, Uint8List?> _cache = <String, Uint8List?>{};
  static _Win32IconApis? _apis;
  static bool _initialized = false;

  static void _ensureInitialized() {
    if (_initialized || !Platform.isWindows) return;
    _initialized = true;
    try {
      final shell32 = DynamicLibrary.open('shell32.dll');
      final user32 = DynamicLibrary.open('user32.dll');
      final gdi32 = DynamicLibrary.open('gdi32.dll');

      _apis = _Win32IconApis(
        privateExtractIconsW: user32
            .lookupFunction<
              Uint32 Function(
                Pointer<Utf16>,
                Int32,
                Int32,
                Int32,
                Pointer<IntPtr>,
                Pointer<Uint32>,
                Uint32,
                Uint32,
              ),
              int Function(
                Pointer<Utf16>,
                int,
                int,
                int,
                Pointer<IntPtr>,
                Pointer<Uint32>,
                int,
                int,
              )
            >('PrivateExtractIconsW'),
        extractIconExW: shell32
            .lookupFunction<
              Uint32 Function(Pointer<Utf16>, Int32, Pointer<IntPtr>, Pointer<IntPtr>, Uint32),
              int Function(Pointer<Utf16>, int, Pointer<IntPtr>, Pointer<IntPtr>, int)
            >('ExtractIconExW'),
        getIconInfo: user32
            .lookupFunction<
              Int32 Function(IntPtr, Pointer<_ICONINFO>),
              int Function(int, Pointer<_ICONINFO>)
            >('GetIconInfo'),
        destroyIcon: user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DestroyIcon'),
        getObjectW: gdi32
            .lookupFunction<
              Int32 Function(IntPtr, Int32, Pointer<Void>),
              int Function(int, int, Pointer<Void>)
            >('GetObjectW'),
        createCompatibleDC: gdi32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('CreateCompatibleDC'),
        deleteDC: gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteDC'),
        deleteObject: gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteObject'),
        getDIBits: gdi32
            .lookupFunction<
              Int32 Function(
                IntPtr,
                IntPtr,
                Uint32,
                Uint32,
                Pointer<Uint8>,
                Pointer<_BITMAPINFOHEADER>,
                Uint32,
              ),
              int Function(
                int,
                int,
                int,
                int,
                Pointer<Uint8>,
                Pointer<_BITMAPINFOHEADER>,
                int,
              )
            >('GetDIBits'),
      );
    } catch (_) {
      // Ignore FFI lookup failures on non-standard environments.
    }
  }

  /// Parses a registry DisplayIcon or file path into `(filePath, iconIndex)`.
  static ({String filePath, int iconIndex})? parseIconLocation(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    var iconIndex = 0;
    final indexMatch = RegExp(r',\s*(-?\d+)\s*$').firstMatch(trimmed);
    if (indexMatch != null) {
      iconIndex = int.tryParse(indexMatch.group(1)!) ?? 0;
      trimmed = trimmed.substring(0, indexMatch.start).trim();
    }

    if (trimmed.startsWith('"')) {
      final endQuote = trimmed.indexOf('"', 1);
      if (endQuote > 1) {
        trimmed = trimmed.substring(1, endQuote).trim();
      } else {
        trimmed = trimmed.replaceAll('"', '').trim();
      }
    } else {
      final fileMatch = RegExp(
        r'^([a-zA-Z]:\\[^"]*?\.(?:exe|ico|dll))\b',
        caseSensitive: false,
      ).firstMatch(trimmed);
      if (fileMatch != null) {
        trimmed = fileMatch.group(1)!.trim();
      }
    }

    if (trimmed.isEmpty) return null;
    final normalized = trimmed.replaceAll('/', r'\');
    final lower = normalized.toLowerCase();
    if (!lower.endsWith('.exe') && !lower.endsWith('.ico') && !lower.endsWith('.dll')) {
      return null;
    }
    return (filePath: normalized, iconIndex: iconIndex);
  }

  /// Extracts a 48x48 (or native size) RGBA PNG icon from a `.exe`, `.ico`, or `.dll` source.
  static Uint8List? extractIconPng(String rawSource, {int preferredSize = 48}) {
    final parsed = parseIconLocation(rawSource);
    if (parsed == null) return null;

    final cacheKey = '${parsed.filePath.toLowerCase()},${parsed.iconIndex}@$preferredSize';
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey];
    }

    if (!Platform.isWindows) {
      return null;
    }

    final file = File(parsed.filePath);
    if (!file.existsSync()) {
      _cache[cacheKey] = null;
      return null;
    }

    _ensureInitialized();
    final apis = _apis;
    if (apis == null) {
      return null;
    }

    return using((Arena arena) {
      final pathPtr = parsed.filePath.toNativeUtf16(allocator: arena);
      var hIcon = 0;

      final hIconPtr = arena<IntPtr>();
      final iconIdPtr = arena<Uint32>();
      final extracted = apis.privateExtractIconsW(
        pathPtr,
        parsed.iconIndex,
        preferredSize,
        preferredSize,
        hIconPtr,
        iconIdPtr,
        1,
        0,
      );
      if (extracted > 0 && hIconPtr.value != 0) {
        hIcon = hIconPtr.value;
      }

      if (hIcon == 0) {
        final largePtr = arena<IntPtr>();
        final smallPtr = arena<IntPtr>();
        final count = apis.extractIconExW(pathPtr, parsed.iconIndex, largePtr, smallPtr, 1);
        if (count > 0) {
          if (largePtr.value != 0) {
            hIcon = largePtr.value;
            if (smallPtr.value != 0) apis.destroyIcon(smallPtr.value);
          } else if (smallPtr.value != 0) {
            hIcon = smallPtr.value;
          }
        }
      }

      if (hIcon == 0 && parsed.iconIndex != 0) {
        final largePtr = arena<IntPtr>();
        final smallPtr = arena<IntPtr>();
        final count = apis.extractIconExW(pathPtr, 0, largePtr, smallPtr, 1);
        if (count > 0) {
          if (largePtr.value != 0) {
            hIcon = largePtr.value;
            if (smallPtr.value != 0) apis.destroyIcon(smallPtr.value);
          } else if (smallPtr.value != 0) {
            hIcon = smallPtr.value;
          }
        }
      }

      if (hIcon == 0) {
        _cache[cacheKey] = null;
        return null;
      }

      try {
        final png = _hIconToPng(apis, hIcon, arena);
        _cache[cacheKey] = png;
        return png;
      } finally {
        apis.destroyIcon(hIcon);
      }
    });
  }

  static Uint8List? _hIconToPng(_Win32IconApis apis, int hIcon, Arena arena) {
    final iconInfo = arena<_ICONINFO>();
    if (apis.getIconInfo(hIcon, iconInfo) == 0) {
      return null;
    }

    final hbmColor = iconInfo.ref.hbmColor;
    final hbmMask = iconInfo.ref.hbmMask;
    final targetBmp = hbmColor != 0 ? hbmColor : hbmMask;
    if (targetBmp == 0) {
      return null;
    }

    final hdc = apis.createCompatibleDC(0);
    try {
      final bmp = arena<_BITMAP>();
      if (apis.getObjectW(targetBmp, sizeOf<_BITMAP>(), bmp.cast<Void>()) == 0) {
        return null;
      }

      final width = bmp.ref.bmWidth;
      final height = hbmColor != 0 ? bmp.ref.bmHeight.abs() : (bmp.ref.bmHeight.abs() ~/ 2);
      if (width <= 0 || height <= 0 || width > 512 || height > 512) {
        return null;
      }

      final pixelCount = width * height;
      final byteLength = pixelCount * 4;
      final colorBits = arena<Uint8>(byteLength);
      final bmi = arena<_BITMAPINFOHEADER>()
        ..ref.biSize = 40
        ..ref.biWidth = width
        ..ref.biHeight = -height // top-down DIB
        ..ref.biPlanes = 1
        ..ref.biBitCount = 32
        ..ref.biCompression = 0;

      final scanlines = apis.getDIBits(hdc, targetBmp, 0, height, colorBits, bmi, 0);
      if (scanlines == 0) {
        return null;
      }

      final bgra = colorBits.asTypedList(byteLength);
      var hasNonZeroAlpha = false;
      for (var i = 3; i < byteLength; i += 4) {
        if (bgra[i] != 0) {
          hasNonZeroAlpha = true;
          break;
        }
      }

      final rgba = Uint8List(byteLength);
      if (hasNonZeroAlpha) {
        for (var i = 0; i < byteLength; i += 4) {
          rgba[i] = bgra[i + 2]; // R
          rgba[i + 1] = bgra[i + 1]; // G
          rgba[i + 2] = bgra[i]; // B
          rgba[i + 3] = bgra[i + 3]; // A
        }
      } else if (hbmMask != 0) {
        final maskBits = arena<Uint8>(byteLength);
        final maskBmi = arena<_BITMAPINFOHEADER>()
          ..ref.biSize = 40
          ..ref.biWidth = width
          ..ref.biHeight = -height
          ..ref.biPlanes = 1
          ..ref.biBitCount = 32
          ..ref.biCompression = 0;
        final maskLines = apis.getDIBits(hdc, hbmMask, 0, height, maskBits, maskBmi, 0);
        final mask = maskLines > 0 ? maskBits.asTypedList(byteLength) : null;
        for (var i = 0; i < byteLength; i += 4) {
          rgba[i] = bgra[i + 2];
          rgba[i + 1] = bgra[i + 1];
          rgba[i + 2] = bgra[i];
          rgba[i + 3] = (mask != null && mask[i] != 0) ? 0 : 255;
        }
      } else {
        for (var i = 0; i < byteLength; i += 4) {
          rgba[i] = bgra[i + 2];
          rgba[i + 1] = bgra[i + 1];
          rgba[i + 2] = bgra[i];
          rgba[i + 3] = 255;
        }
      }

      return encodeRgbaPng(width: width, height: height, rgba: rgba);
    } finally {
      if (hdc != 0) apis.deleteDC(hdc);
      if (hbmColor != 0) apis.deleteObject(hbmColor);
      if (hbmMask != 0) apis.deleteObject(hbmMask);
    }
  }

  /// Encodes raw top-down RGBA bytes into a standard PNG image in memory.
  @visibleForTesting
  static Uint8List encodeRgbaPng({
    required int width,
    required int height,
    required Uint8List rgba,
  }) {
    final rowStride = width * 4;
    final rawScanlines = Uint8List((rowStride + 1) * height);
    for (var y = 0; y < height; y++) {
      final dstOffset = y * (rowStride + 1);
      rawScanlines[dstOffset] = 0; // Filter type 0 (None)
      final srcOffset = y * rowStride;
      rawScanlines.setRange(dstOffset + 1, dstOffset + 1 + rowStride, rgba, srcOffset);
    }

    final compressed = zlib.encode(rawScanlines);
    final out = BytesBuilder(copy: false);

    // PNG signature
    out.add(const <int>[137, 80, 78, 71, 13, 10, 26, 10]);

    // IHDR chunk
    final ihdr = ByteData(13)
      ..setUint32(0, width)
      ..setUint32(4, height)
      ..setUint8(8, 8) // bit depth 8
      ..setUint8(9, 6) // color type 6 (RGBA)
      ..setUint8(10, 0) // compression 0
      ..setUint8(11, 0) // filter 0
      ..setUint8(12, 0); // interlace 0
    _writePngChunk(out, const <int>[0x49, 0x48, 0x44, 0x52], ihdr.buffer.asUint8List());

    // IDAT chunk
    _writePngChunk(out, const <int>[0x49, 0x44, 0x41, 0x54], compressed);

    // IEND chunk
    _writePngChunk(out, const <int>[0x49, 0x45, 0x4E, 0x44], const <int>[]);

    return out.toBytes();
  }

  static void _writePngChunk(BytesBuilder out, List<int> type, List<int> data) {
    final lenBytes = ByteData(4)..setUint32(0, data.length);
    out.add(lenBytes.buffer.asUint8List());
    out.add(type);
    if (data.isNotEmpty) {
      out.add(data);
    }
    final crc = _crc32(type, data);
    final crcBytes = ByteData(4)..setUint32(0, crc);
    out.add(crcBytes.buffer.asUint8List());
  }

  static final List<int> _crcTable = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    return c;
  }, growable: false);

  static int _crc32(List<int> type, List<int> data) {
    var c = 0xFFFFFFFF;
    for (var i = 0; i < type.length; i++) {
      c = _crcTable[(c ^ type[i]) & 0xFF] ^ (c >>> 8);
    }
    for (var i = 0; i < data.length; i++) {
      c = _crcTable[(c ^ data[i]) & 0xFF] ^ (c >>> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
