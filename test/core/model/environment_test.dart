import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/model/environment.dart';

void main() {
  test('release dart define selects the matching build contract', () {
    const configuredRelease = String.fromEnvironment('release', defaultValue: 'general');

    expect(Release.read().key, configuredRelease);
  });
}
