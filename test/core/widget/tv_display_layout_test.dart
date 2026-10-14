import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/device/android_tv_provider.dart';
import 'package:zeon/core/theme/app_theme.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/core/widget/keyboard_focus_outline.dart';
import 'package:zeon/core/widget/tv_display_layout.dart';

void main() {
  test('TV detection uses platform features rather than display dimensions', () {
    expect(hasAndroidTvFeatures(['android.software.leanback']), isTrue);
    expect(hasAndroidTvFeatures(['android.hardware.type.television']), isTrue);
    expect(hasAndroidTvFeatures(['android.hardware.touchscreen', 'android.hardware.wifi']), isFalse);
    expect(hasAndroidTvFeatures([]), isFalse);
  });

  testWidgets('TV layout scales coordinates and insets while retaining accessibility preferences', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const source = MediaQueryData(
      size: Size(960, 540),
      devicePixelRatio: 2,
      padding: EdgeInsets.all(12),
      viewPadding: EdgeInsets.all(12),
      viewInsets: EdgeInsets.only(bottom: 150),
      systemGestureInsets: EdgeInsets.all(6),
      textScaler: TextScaler.linear(1.5),
      disableAnimations: true,
    );
    late MediaQueryData actual;
    late BoxConstraints layout;
    await tester.pumpWidget(
      MediaQuery(
        data: source,
        child: TvDisplayLayout(
          isTelevision: true,
          child: MaterialApp(
            home: LayoutBuilder(
              builder: (context, constraints) {
                actual = MediaQuery.of(context);
                layout = constraints;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    expect(layout.biggest, const Size(1280, 720));
    expect(actual.size, layout.biggest);
    expect(actual.devicePixelRatio, 1.5);
    expect(actual.padding, const EdgeInsets.all(16));
    expect(actual.viewPadding, const EdgeInsets.all(16));
    expect(actual.viewInsets.bottom, 200);
    expect(actual.systemGestureInsets, const EdgeInsets.all(8));
    expect(actual.textScaler.scale(16), 24);
    expect(actual.disableAnimations, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('non-TV preserves media and control size', (tester) async {
    const source = MediaQueryData(size: Size(800, 600), devicePixelRatio: 2);
    late MediaQueryData actual;
    await tester.pumpWidget(
      MediaQuery(
        data: source,
        child: TvDisplayLayout(
          isTelevision: false,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Builder(
              builder: (context) {
                actual = MediaQuery.of(context);
                return const Center(child: SizedBox(key: ValueKey('control'), width: 120, height: 48));
              },
            ),
          ),
        ),
      ),
    );
    expect(identical(actual, source), isTrue);
    expect(tester.getSize(find.byKey(const ValueKey('control'))), const Size(120, 48));
    expect(find.byType(FittedBox), findsNothing);
  });

  testWidgets('scaled controls retain pointer and remote activation; dialogs share the viewport', (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final buttonFocus = FocusNode();
    addTearDown(buttonFocus.dispose);
    var activations = 0;
    Size? dialogViewport;
    await tester.pumpWidget(
      TvDisplayLayout(
        isTelevision: true,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: SizedBox(
                  width: 160,
                  height: 64,
                  child: FilledButton(
                    key: const ValueKey('control'),
                    focusNode: buttonFocus,
                    autofocus: true,
                    onPressed: () {
                      activations++;
                    },
                    child: const Text('Connect'),
                  ),
                ),
              ),
              floatingActionButton: FloatingActionButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) {
                    dialogViewport = MediaQuery.sizeOf(context);
                    return const AlertDialog(content: Text('Dialog'));
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final box = tester.renderObject<RenderBox>(find.byKey(const ValueKey('control')));
    expect(
      box.localToGlobal(Offset(box.size.width, box.size.height)) - box.localToGlobal(Offset.zero),
      const Offset(120, 48),
    );
    expect(buttonFocus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(activations, 1);
    await tester.tap(find.byKey(const ValueKey('control')));
    expect(activations, 2);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(dialogViewport, const Size(1280, 720));
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV dialog retains input through IME changes and restores route focus on Back', (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final launcherFocus = FocusNode();
    final inputFocus = FocusNode();
    final controller = TextEditingController();
    addTearDown(launcherFocus.dispose);
    addTearDown(inputFocus.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      TvDisplayLayout(
        isTelevision: true,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  autofocus: true,
                  focusNode: launcherFocus,
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => AlertDialog(
                      content: TextField(autofocus: true, focusNode: inputFocus, controller: controller),
                    ),
                  ),
                  child: const Text('Link account'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(inputFocus.hasFocus, isTrue);
    expect(launcherFocus.hasFocus, isFalse);
    await tester.enterText(find.byType(TextField), 'synthetic-code');
    const selection = TextSelection(baseOffset: 2, extentOffset: 7);
    tester.testTextInput.updateEditingValue(controller.value.copyWith(selection: selection));
    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    await tester.pumpAndSettle();
    expect(inputFocus.hasFocus, isTrue);
    expect(controller.text, 'synthetic-code');
    expect(controller.selection, selection);
    final field = tester.renderObject<RenderBox>(find.byType(TextField));
    expect(field.localToGlobal(Offset(0, field.size.height)).dy, lessThanOrEqualTo(340));
    expect(tester.takeException(), isNull);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(controller.text, 'synthetic-code');
    expect(controller.selection, selection);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(launcherFocus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(controller.text, 'synthetic-code');
    expect(inputFocus.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV shows initial remote focus without a key and restores the prior input policy', (tester) async {
    final original = FocusManager.instance.highlightStrategy;
    addTearDown(() => FocusManager.instance.highlightStrategy = original);
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
    final television = ValueNotifier(true);
    addTearDown(television.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder<bool>(
        valueListenable: television,
        builder: (_, value, child) => TvDisplayLayout(isTelevision: value, child: child!),
        child: MaterialApp(
          theme: AppTheme(AppThemeMode.dark, 'Montserrat').darkTheme(null),
          home: Scaffold(
            body: Center(
              child: FilledButton(autofocus: true, onPressed: () {}, child: const Text('Connect')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final outlines = find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.foregroundPainter is KeyboardFocusOutlinePainter,
    );
    expect(FocusManager.instance.highlightStrategy, FocusHighlightStrategy.alwaysTraditional);
    expect(outlines, findsOneWidget, reason: 'A remote user must see the first action before pressing any key.');
    television.value = false;
    await tester.pumpAndSettle();
    expect(FocusManager.instance.highlightStrategy, FocusHighlightStrategy.alwaysTouch);
    expect(outlines, findsNothing);
    television.value = true;
    await tester.pumpAndSettle();
    expect(FocusManager.instance.highlightStrategy, FocusHighlightStrategy.alwaysTraditional);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(FocusManager.instance.highlightStrategy, FocusHighlightStrategy.alwaysTouch);
    expect(tester.takeException(), isNull);
  });
}
