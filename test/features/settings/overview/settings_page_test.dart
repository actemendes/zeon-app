import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/app_info/app_info_provider.dart';
import 'package:zeon/core/model/environment.dart';
import 'package:zeon/features/settings/overview/settings_page.dart';
import 'package:zeon/gen/translations_ru.g.dart';

import '../../ui/approved_interface_test.dart' as fixtures;

void main() {
  test('manual app update action is hidden for store releases', () {
    expect(shouldShowManualAppUpdate(Release.general, isIOS: false), isTrue);
    expect(shouldShowManualAppUpdate(Release.googlePlay, isIOS: false), isFalse);
    expect(shouldShowManualAppUpdate(Release.appStore, isIOS: false), isFalse);
    expect(shouldShowManualAppUpdate(Release.general, isIOS: true), isFalse);
  });

  testWidgets('settings renders manual updates only for the sideload release', (tester) async {
    final container = await fixtures.pumpPage(tester, SettingsPage(), size: const Size(1280, 720));
    final appInfo = container.read(appInfoProvider).requireValue;
    final updateAction = find.text(TranslationsRu().pages.about.checkForUpdate);

    expect(updateAction, findsOneWidget);
    for (final release in [Release.googlePlay, Release.appStore, Release.general]) {
      container.read(appInfoProvider.notifier).state = AsyncData(appInfo.copyWith(release: release));
      await tester.pump();
      expect(updateAction, release == Release.general ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}
