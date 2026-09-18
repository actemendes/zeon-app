import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/ios_lab_ui_test.dart' as suite;

void main() {
  if (!Platform.isIOS || Platform.environment['SIMULATOR_DEVICE_NAME'] == null) {
    throw StateError('This suite is Simulator UI/logic evidence only');
  }
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
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
