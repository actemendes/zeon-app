import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';

void main() {
  test('Android does not subscribe to the recursive hcore log stream', () {
    expect(coreLogStreamingEnabledForPlatform(isAndroid: true), isFalse);
    expect(coreLogStreamingEnabledForPlatform(isAndroid: false), isTrue);
  });

  test('Android never enables the recursive native debug bridge', () {
    expect(
      coreSetupDebugEnabledForPlatform(isAndroid: true, userDebugEnabled: false, isDebugBuild: true),
      isFalse,
    );
    expect(
      coreSetupDebugEnabledForPlatform(isAndroid: true, userDebugEnabled: true, isDebugBuild: false),
      isFalse,
    );
  });

  test('non-Android keeps user and build debug semantics', () {
    expect(
      coreSetupDebugEnabledForPlatform(isAndroid: false, userDebugEnabled: false, isDebugBuild: false),
      isFalse,
    );
    expect(
      coreSetupDebugEnabledForPlatform(isAndroid: false, userDebugEnabled: true, isDebugBuild: false),
      isTrue,
    );
    expect(
      coreSetupDebugEnabledForPlatform(isAndroid: false, userDebugEnabled: false, isDebugBuild: true),
      isTrue,
    );
  });
}
