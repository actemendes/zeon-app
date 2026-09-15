import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('applications list does not expose the auto-selection action', () async {
    final source = await File('lib/features/per_app_proxy/overview/per_app_proxy_page.dart').readAsString();

    expect(source, isNot(contains('showAutoAppsSelection')));
    expect(source, isNot(contains('FloatingActionButton.extended')));
    expect(source, contains('floatingActionButton: showScrollToTop.value'));
    expect(source, contains('Icons.keyboard_arrow_up_rounded'));
  });
}
