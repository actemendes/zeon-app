import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() {
  final directory = Platform.environment['ZEON_IOS_LAB_EVIDENCE'];
  if (directory == null) throw StateError('External evidence directory is required');
  return integrationDriver(
    timeout: const Duration(minutes: 5),
    writeResponseOnFailure: true,
    responseDataCallback: (data) => writeResponseData(data, destinationDirectory: directory),
  );
}
