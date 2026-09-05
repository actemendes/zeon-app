import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/zeoncore/core_interface/core_interface_desktop.dart';

void main() {
  test('desktop core management stays on an explicit IPv4 loopback', () {
    final address = InternetAddress.tryParse(CoreInterfaceDesktop.managementHost);

    expect(address, isNotNull);
    expect(address!.type, InternetAddressType.IPv4);
    expect(address.isLoopback, isTrue);
    expect(CoreInterfaceDesktop.managementHost, '127.0.0.1');
  });
}
