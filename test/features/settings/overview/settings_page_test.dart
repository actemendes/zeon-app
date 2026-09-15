import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/model/environment.dart';
import 'package:zeon/features/settings/overview/settings_page.dart';

void main() {
  test('manual GitHub update action is hidden for store releases', () {
    expect(shouldShowManualAppUpdate(Release.general, isIOS: false), isTrue);
    expect(shouldShowManualAppUpdate(Release.googlePlay, isIOS: false), isFalse);
    expect(shouldShowManualAppUpdate(Release.appStore, isIOS: false), isFalse);
    expect(shouldShowManualAppUpdate(Release.general, isIOS: true), isFalse);
  });
}
