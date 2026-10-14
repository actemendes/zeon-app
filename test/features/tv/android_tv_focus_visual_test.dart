import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/router/dialog/widgets/zeon_dialog.dart';
import 'package:zeon/core/theme/app_theme.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/core/widget/keyboard_focus_outline.dart';
import 'package:zeon/features/home/widget/home_premium_access_view.dart';
import 'package:zeon/features/profile/overview/profile_menu_page.dart';
import 'package:zeon/features/proxy/active/active_proxy_card.dart';
import 'package:zeon/features/proxy/widget/proxy_tile.dart';
import 'package:zeon/features/settings/widget/settings_surface.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

import '../ui/approved_interface_test.dart' as fixtures;

Finder get visibleFocusOutlines => find.byWidgetPredicate(
  (widget) => widget is CustomPaint && widget.foregroundPainter is KeyboardFocusOutlinePainter,
);

void main() {
  for (final mode in [AppThemeMode.light, AppThemeMode.dark, AppThemeMode.amoled]) {
    testWidgets('remote focus contrasts with a green button and hides on touch in $mode', (tester) async {
      final appTheme = AppTheme(mode, 'Montserrat');
      final theme = mode == AppThemeMode.light ? appTheme.lightTheme(null) : appTheme.darkTheme(null);
      final boundaryKey = GlobalKey();
      var activations = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: SizedBox(
                  width: 240,
                  height: 80,
                  child: FilledButton(
                    onPressed: () => activations++,
                    // A local style must not remove the themed focus layer.
                    style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.primary),
                    child: const Text('Connect'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(visibleFocusOutlines, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      expect(activations, 1);
      await tester.pumpAndSettle();

      final boundary = boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = (await image.toByteData())!;
        Color pixel(int x, int y) {
          final i = (y * image.width + x) * 4;
          return Color.fromARGB(bytes.getUint8(i + 3), bytes.getUint8(i), bytes.getUint8(i + 1), bytes.getUint8(i + 2));
        }

        expect(pixel(120, 1), const Color(0xFF101010), reason: 'Dark separation must remain above the green fill.');
        expect(pixel(120, 4), theme.colorScheme.primary, reason: 'The green focus stroke must actually render.');
        expect(pixel(120, 7), const Color(0xFF101010));
        const evidence = String.fromEnvironment('FOCUS_EVIDENCE_DIR');
        if (evidence.isNotEmpty) {
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          await File('$evidence/focus-${mode.name}.png').writeAsBytes(png.buffer.asUint8List());
        }
        image.dispose();
      });

      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(activations, 2);
      expect(visibleFocusOutlines, findsNothing, reason: 'Touch input retains the existing button appearance.');
    });
  }

  testWidgets('remote follows settings, custom premium action and dialog without losing its outline', (tester) async {
    var setting = false;
    var premiumTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme(AppThemeMode.dark, 'Montserrat').darkTheme(null),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SizedBox(
              width: 500,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SettingsSwitch(
                    title: const Text('Example setting'),
                    value: setting,
                    onChanged: (value) => setState(() => setting = value),
                  ),
                  HomePremiumAccessView(
                    remainingDays: 4,
                    label: 'Premium',
                    title: 'Premium',
                    subtitle: 'Example',
                    onPressed: () {
                      premiumTaps++;
                      showDialog<void>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('Example dialog'),
                          actions: [
                            TextButton(
                              autofocus: true,
                              onPressed: () => Navigator.of(dialogContext).pop(),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(SettingsSwitch), matching: visibleFocusOutlines), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(setting, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(HomePremiumAccessView), matching: visibleFocusOutlines), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(premiumTaps, 1);
    expect(find.descendant(of: find.byType(AlertDialog), matching: visibleFocusOutlines), findsOneWidget);
    expect(find.descendant(of: find.byType(HomePremiumAccessView), matching: visibleFocusOutlines), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('the profile menu exposes a visible remote focus and activates its account action', (tester) async {
    await fixtures.pumpPage(tester, const ProfileMenuPage(), size: const Size(960, 540));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(ProfileMenuPage), matching: visibleFocusOutlines), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(ProfileMenuPage), findsNothing);
  });

  testWidgets('ZeonDialog retains focused input and both action outlines through its local themes', (tester) async {
    var confirmed = false;
    final fieldFocus = FocusNode();
    addTearDown(fieldFocus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme(AppThemeMode.light, 'Montserrat').lightTheme(null),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              autofocus: true,
              onPressed: () => showZeonDialog<void>(
                context,
                Builder(
                  builder: (dialogContext) => ZeonDialog(
                    title: const Text('Edit setting'),
                    content: TextField(focusNode: fieldFocus, autofocus: true),
                    actions: [
                      TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
                      TextButton(
                        onPressed: () {
                          confirmed = true;
                          Navigator.of(dialogContext).pop();
                        },
                        child: const Text('Confirm'),
                      ),
                    ],
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(fieldFocus.hasFocus, isTrue);
    final input = tester.widget<InputDecorator>(find.byType(InputDecorator));
    expect(input.decoration.focusedBorder!.borderSide.width, 4);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.widgetWithText(TextButton, 'Cancel'), matching: visibleFocusOutlines),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.widgetWithText(TextButton, 'Confirm'), matching: visibleFocusOutlines),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
    expect(find.byType(ZeonDialog), findsNothing);
  });

  for (final selected in [false, true]) {
    testWidgets('server selection remains distinct from remote focus, selected=$selected', (tester) async {
      var selectedTaps = 0;
      await fixtures.pumpPage(
        tester,
        Scaffold(
          body: ProxyTile(
            OutboundInfo(tag: 'fixture', tagDisplay: 'Example server'),
            selected: selected,
            isActive: selected,
            ipv6Mode: IPv6Mode.disable,
            onTap: () => selectedTaps++,
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(ProxyTile), matching: visibleFocusOutlines), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(selectedTaps, 1);
    });
  }

  testWidgets('connected Home nested server actions paint only the primary focus outline', (tester) async {
    await fixtures.pumpPage(
      tester,
      const Scaffold(body: Center(child: ActiveProxyFooter())),
      size: const Size(960, 540),
    );
    final serverActions = find.descendant(of: find.byType(ActiveProxyFooter), matching: find.byType(InkWell));
    expect(serverActions, findsNWidgets(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(visibleFocusOutlines, findsOneWidget);
    final cardOutlineWidth = tester.getSize(visibleFocusOutlines).width;

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(visibleFocusOutlines, findsOneWidget, reason: 'The parent card must not look focused with its flag action.');
    expect(find.descendant(of: serverActions.last, matching: visibleFocusOutlines), findsOneWidget);
    expect(tester.getSize(visibleFocusOutlines).width, lessThan(cardOutlineWidth));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(visibleFocusOutlines, findsOneWidget);
    expect(tester.getSize(visibleFocusOutlines).width, cardOutlineWidth);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(ActiveProxyFooter), findsNothing, reason: 'Select must invoke the parent server-picker action.');
  });
}
