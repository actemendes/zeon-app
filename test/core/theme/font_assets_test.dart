import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Montserrat ships the interface weights used by the theme', () async {
    final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
    final family = manifest.cast<Map<String, dynamic>>().singleWhere((entry) => entry['family'] == 'Montserrat');
    final fonts = (family['fonts'] as List<dynamic>).cast<Map<String, dynamic>>();

    expect(fonts.map((font) => font['weight']), orderedEquals(<int>[400, 500, 600, 700]));
    expect(fonts.map((font) => font['asset']).toSet(), <String>{'assets/fonts/Montserrat-VariableFont_wght.ttf'});

    final license = await rootBundle.loadString('assets/fonts/OFL-Montserrat.txt');
    expect(license, contains('SIL OPEN FONT LICENSE Version 1.1'));
  });

  test('Montserrat variable face covers every requested interface weight', () async {
    final data = await rootBundle.load('assets/fonts/Montserrat-VariableFont_wght.ttf');
    final tableCount = data.getUint16(4);
    int? fvarOffset;

    for (var index = 0; index < tableCount; index++) {
      final recordOffset = 12 + index * 16;
      if (_tagAt(data, recordOffset) == 'fvar') {
        fvarOffset = data.getUint32(recordOffset + 8);
        break;
      }
    }

    expect(fvarOffset, isNotNull, reason: 'The bundled Montserrat must remain a variable font.');
    final axesOffset = data.getUint16(fvarOffset! + 4);
    final axisCount = data.getUint16(fvarOffset + 8);
    final axisSize = data.getUint16(fvarOffset + 10);
    final weightAxes = <({double min, double max})>[];

    for (var index = 0; index < axisCount; index++) {
      final axisOffset = fvarOffset + axesOffset + index * axisSize;
      if (_tagAt(data, axisOffset) == 'wght') {
        weightAxes.add((min: _fixedAt(data, axisOffset + 4), max: _fixedAt(data, axisOffset + 12)));
      }
    }

    expect(weightAxes, hasLength(1));
    expect(weightAxes.single.min, lessThanOrEqualTo(400));
    expect(weightAxes.single.max, greaterThanOrEqualTo(700));
  });
}

String _tagAt(ByteData data, int offset) =>
    String.fromCharCodes(List<int>.generate(4, (index) => data.getUint8(offset + index)));

double _fixedAt(ByteData data, int offset) => data.getInt32(offset) / 65536;
