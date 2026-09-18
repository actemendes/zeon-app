import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/ios_lab_ui_test.dart' as suite;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!Platform.isIOS ||
        await const MethodChannel('zeon.ios_lab').invokeMethod<String>('environment') != 'SIMULATOR_UI_LOGIC_ONLY') {
      throw StateError('This suite is Simulator UI/logic evidence only');
    }
  });
  binding.reportData = {'evidence_kind': 'UI_LOGIC_ONLY', 'real_ios_vpn': false};
  suite.main();
  tearDownAll(() {
    binding.reportData = {
      'evidence_kind': 'UI_LOGIC_ONLY',
      'real_ios_vpn': false,
      'cases': binding.results.map(
        (name, value) => MapEntry(name.split(' ').first, value == 'success' ? 'PASS' : 'FAIL'),
      ),
    };
  });
}
