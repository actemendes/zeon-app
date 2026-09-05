import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/utils/link_parsers.dart';

void main() {
  test('path segments are decoded exactly once', () {
    final segments = normalizedUriPathSegments(Uri.parse('https://example.com/open/value%2525tail'));

    expect(segments, ['open', 'value%25tail']);
  });

  test('literal percent input is preserved without throwing', () {
    final malformed = Uri.tryParse('https://example.com/open/value%tail');

    expect(malformed, isNotNull);
    expect(normalizedUriPathSegments(malformed!), ['open', 'value%tail']);
  });
}
