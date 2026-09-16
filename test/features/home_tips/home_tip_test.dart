import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/features/home_tips/home_tip.dart';
import 'package:zeon/features/home_tips/home_tip_card.dart';
import 'package:zeon/features/home_tips/home_tip_controller.dart';
import 'package:zeon/features/home_tips/home_tip_provider.dart';

final origin = Uri.parse('https://api.zeon-vps.online');
Map<String, dynamic> payload({String revision = 'a', String? expiry}) => {
  'ok': true,
  'data': {
    'schema_version': 1,
    'tip': {
      'id': 'guide',
      'type': 'image_link',
      'revision': revision * 64,
      'title': 'Полезно знать',
      'image_url': '/tips/v1/assets/${'b' * 64}.png',
      'image_sha256': 'b' * 64,
      'target_url': 'https://example.com/guide',
      'aspect_ratio': 3,
      'expires_at': expiry,
    },
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });
  test('accepts v1 and ignores unknown types, unsafe URLs and invalid ratios', () {
    expect(HomeTip.parse(payload(), origin), isNotNull);
    for (final entry in {
      'type': 'webview',
      'target_url': 'javascript:alert(1)',
      'image_url': 'https://third-party.test/image.png',
      'aspect_ratio': 0,
      'expires_at': 'broken',
    }.entries) {
      final body = payload();
      (body['data']['tip'] as Map)[entry.key] = entry.value;
      expect(HomeTip.parse(body, origin), isNull, reason: entry.key);
    }
  });

  test('old or malformed device bearer cannot request tips for the new account', () {
    final token = 'header.${base64Url.encode(utf8.encode(jsonEncode({'user_id': 1})))}.signature';
    expect(homeTipTokenMatchesUser(token, '1'), isTrue);
    expect(homeTipTokenMatchesUser(token, '2'), isFalse);
    expect(homeTipTokenMatchesUser('broken', '1'), isFalse);
  });

  test('dismissal survives controller restart; a new revision reappears', () async {
    var remote = HomeTip.parse(payload(), origin);
    HomeTipController create() => HomeTipController(
      preferences: preferences,
      currentUser: () => 'fixture',
      fetchTip: () async => remote,
      fetchImage: (_) async => Uint8List.fromList([1]),
    );
    final first = create();
    await first.refresh();
    expect(first.state, isNotNull);
    await first.dismiss();
    first.dispose();
    final second = create();
    addTearDown(second.dispose);
    await second.refresh();
    expect(second.state, isNull);
    remote = HomeTip.parse(payload(revision: 'c'), origin);
    await second.refresh();
    expect(second.state?.tip.revision, 'c' * 64);
  });

  test('server removal, expiry and API/image failures leave no stale content', () async {
    var remote = HomeTip.parse(payload(), origin);
    var fail = false;
    final controller = HomeTipController(
      preferences: preferences,
      currentUser: () => 'fixture',
      fetchTip: () async {
        if (fail) throw StateError('offline');
        return remote;
      },
      fetchImage: (_) async => Uint8List.fromList([1]),
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    expect(controller.state, isNotNull);
    remote = null;
    await controller.refresh();
    expect(controller.state, isNull);
    remote = HomeTip.parse(payload(expiry: '2000-01-01T00:00:00Z'), origin);
    await controller.refresh();
    expect(controller.state, isNull);
    fail = true;
    await controller.refresh();
    expect(controller.state, isNull);
  });

  test('latest refresh wins and another account cannot receive an in-flight response', () async {
    var owner = 'one';
    final pending = <Completer<HomeTip?>>[];
    final controller = HomeTipController(
      preferences: preferences,
      currentUser: () => owner,
      fetchTip: () {
        final next = Completer<HomeTip?>();
        pending.add(next);
        return next.future;
      },
      fetchImage: (_) async => Uint8List.fromList([1]),
    );
    addTearDown(controller.dispose);
    final first = controller.refresh();
    final second = controller.refresh();
    pending[1].complete(HomeTip.parse(payload(revision: 'c'), origin));
    await second;
    pending[0].complete(HomeTip.parse(payload(), origin));
    await first;
    expect(controller.state?.tip.revision, 'c' * 64);
    final third = controller.refresh();
    owner = 'two';
    pending[2].complete(HomeTip.parse(payload(), origin));
    await third;
    expect(controller.state, isNull);
  });

  testWidgets('card adapts to narrow layout, exposes link and dismisses on close', (tester) async {
    final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
    );
    final controller = HomeTipController(
      preferences: preferences,
      currentUser: () => 'fixture',
      fetchTip: () async => HomeTip.parse(payload(), origin),
      fetchImage: (_) async => image,
    );
    await controller.refresh();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [homeTipProvider.overrideWith((ref) => controller)],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 280,
              child: Consumer(
                builder: (context, ref, _) {
                  final content = ref.watch(homeTipProvider);
                  return content == null ? const SizedBox.shrink() : HomeTipCard(content: content);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home_tip_open')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('home_tip_dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home_tip_open')), findsNothing);
  });
}
