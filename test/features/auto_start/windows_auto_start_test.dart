import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:win32/win32.dart';
import 'package:win32_registry/win32_registry.dart';
import 'package:zeon/features/auto_start/data/windows_auto_start.dart';

void main() {
  group('Windows auto start in a fresh profile', () {
    late String rootPath;
    late WindowsAutoStart startup;

    setUp(() {
      rootPath = 'Software\\ZEON-AutoStart-Test-$pid-${DateTime.now().microsecondsSinceEpoch}';
      startup = WindowsAutoStart(
        appName: 'ZEON-test',
        executablePath: r'C:\Test App\ZEON.exe',
        runKeyPath: '$rootPath\\Run',
        approvedKeyPath: '$rootPath\\Approved',
      );
    });

    tearDown(() {
      final root = Registry.currentUser;
      try {
        root.deleteKey(rootPath, recursive: true);
      } finally {
        root.close();
      }
    });

    void write(String path, RegistryValue value) {
      final root = Registry.currentUser;
      final key = root.createKey(path);
      try {
        key.createValue(value);
      } finally {
        key.close();
        root.close();
      }
    }

    test('absent startup keys are disabled and reads/disable do not create them', () {
      expect(startup.isEnabled(), isFalse);
      startup.disable();
      startup.disable();
      expect(
        () => Registry.openPath(RegistryHive.currentUser, path: rootPath),
        throwsA(isA<WindowsException>().having((error) => error.hr, 'hr', HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND))),
      );
    });

    test('explicit enable creates missing keys and quotes the executable path', () {
      startup.enable();
      expect(startup.isEnabled(), isTrue);
      final key = Registry.openPath(RegistryHive.currentUser, path: startup.runKeyPath);
      try {
        expect(key.getStringValue(startup.appName), '"${startup.executablePath}"');
      } finally {
        key.close();
      }
      startup.disable();
      expect(startup.isEnabled(), isFalse);
      startup.disable();
    });

    test('legacy entry without StartupApproved remains enabled', () {
      write(startup.runKeyPath, RegistryValue.string(startup.appName, startup.executablePath));
      expect(startup.isEnabled(), isTrue);
    });

    test('Task Manager disabled state is preserved until explicit enable', () {
      startup.enable();
      write(startup.approvedKeyPath, RegistryValue.binary(startup.appName, Uint8List(12)..[0] = 3));
      expect(startup.isEnabled(), isFalse);
      startup.enable();
      expect(startup.isEnabled(), isTrue);
    });

    test('disable preserves other applications and a registration owned by another executable', () {
      startup.enable();
      write(startup.runKeyPath, const RegistryValue.string('OtherApp', 'keep'));
      write(startup.runKeyPath, RegistryValue.string(startup.appName, r'C:\Other\ZEON.exe'));
      startup.disable();
      final key = Registry.openPath(RegistryHive.currentUser, path: startup.runKeyPath);
      try {
        expect(key.getStringValue('OtherApp'), 'keep');
        expect(key.getStringValue(startup.appName), r'C:\Other\ZEON.exe');
      } finally {
        key.close();
      }
    });
  }, skip: !Platform.isWindows);
}
