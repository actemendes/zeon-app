import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Montserrat keeps normal copy at Medium and ships thicker static faces', () async {
    final fonts = await _familyFonts('Montserrat');

    expect(fonts, <String, int>{
      'assets/fonts/Montserrat-Medium.ttf': 500,
      'assets/fonts/Montserrat-SemiBold.ttf': 600,
      'assets/fonts/Montserrat-Bold.ttf': 700,
    });
    await _expectStaticWeights(fonts);
    expect(
      await rootBundle.loadString('assets/fonts/OFL-Montserrat.txt'),
      contains('SIL OPEN FONT LICENSE Version 1.1'),
    );
  });

  test('Unbounded ships a distinct static face for every interface weight', () async {
    final fonts = await _familyFonts('Unbounded');

    expect(fonts, <String, int>{
      'assets/fonts/Unbounded-Light.ttf': 300,
      'assets/fonts/Unbounded-Regular.ttf': 400,
      'assets/fonts/Unbounded-Medium.ttf': 500,
      'assets/fonts/Unbounded-SemiBold.ttf': 600,
      'assets/fonts/Unbounded-Bold.ttf': 700,
    });
    await _expectStaticWeights(fonts);
    expect(
      await rootBundle.loadString('assets/fonts/OFL-Unbounded.txt'),
      contains('SIL OPEN FONT LICENSE Version 1.1'),
    );
  });
}

Future<Map<String, int>> _familyFonts(String familyName) async {
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
  final family = manifest.cast<Map<String, dynamic>>().singleWhere((entry) => entry['family'] == familyName);
  final fonts = (family['fonts'] as List<dynamic>).cast<Map<String, dynamic>>();
  return <String, int>{for (final font in fonts) font['asset'] as String: font['weight'] as int};
}

Future<void> _expectStaticWeights(Map<String, int> fonts) async {
  for (final entry in fonts.entries) {
    final data = await rootBundle.load(entry.key);
    expect(_tableOffset(data, 'fvar'), isNull, reason: '${entry.key} must be a static font face.');
    final os2Offset = _tableOffset(data, 'OS/2');
    expect(os2Offset, isNotNull, reason: '${entry.key} must contain OS/2 weight metadata.');
    expect(data.getUint16(os2Offset! + 4), entry.value, reason: '${entry.key} has the wrong internal weight.');
  }
}

int? _tableOffset(ByteData data, String wantedTag) {
  final tableCount = data.getUint16(4);
  for (var index = 0; index < tableCount; index++) {
    final recordOffset = 12 + index * 16;
    if (_tagAt(data, recordOffset) == wantedTag) {
      return data.getUint32(recordOffset + 8);
    }
  }
  return null;
}

String _tagAt(ByteData data, int offset) =>
    String.fromCharCodes(List<int>.generate(4, (index) => data.getUint8(offset + index)));
