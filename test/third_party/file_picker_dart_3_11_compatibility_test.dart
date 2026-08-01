import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final channel = MethodChannel(
    'miguelruivo.flutter.plugins.filepicker',
    Platform.isLinux || Platform.isWindows || Platform.isMacOS ? const JSONMethodCodec() : const StandardMethodCodec(),
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('PlatformFile.fromMap preserves typed platform-channel fields', () {
    final bytes = Uint8List.fromList(<int>[0, 1, 2, 255]);

    final file = PlatformFile.fromMap(<String, Object?>{
      'name': 'профиль.json',
      'path': null,
      'bytes': bytes,
      'size': bytes.length,
      'identifier': 'content://zeon/профиль.json',
    });

    expect(file.name, 'профиль.json');
    expect(file.path, isNull);
    expect(file.bytes, same(bytes));
    expect(file.size, bytes.length);
    expect(file.identifier, 'content://zeon/профиль.json');
  });

  test('FilePickerIO returns null when native picker is cancelled', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => null,
    );

    final result = await FilePickerIO().pickFiles();

    expect(result, isNull);
  });

  test('FilePickerIO creates a readable stream from a typed native path', () async {
    final directory = await Directory.systemTemp.createTemp('zeon-picker-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}${Platform.pathSeparator}профиль.json');
    final payload = List<int>.generate(1024 * 1024, (index) => index & 0xff);
    await source.writeAsBytes(payload, flush: true);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => <Map<String, Object?>>[
        <String, Object?>{
          'name': 'профиль.json',
          'path': source.path,
          'bytes': null,
          'size': payload.length,
          'identifier': source.uri.toString(),
        },
      ],
    );

    final result = await FilePickerIO().pickFiles(withReadStream: true);
    final file = result!.files.single;
    final streamedBytes = await file.readStream!.expand<int>((chunk) => chunk).toList();

    expect(file.path, source.path);
    expect(file.name, 'профиль.json');
    expect(file.size, payload.length);
    expect(file.bytes, isNull);
    expect(streamedBytes, payload);
  });

  test('FilePickerIO propagates native platform errors', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'read_failed', message: 'The selected file cannot be read'),
    );

    await expectLater(FilePickerIO().pickFiles(), throwsA(isA<PlatformException>()));
  });
}
