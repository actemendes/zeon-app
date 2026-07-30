import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/route_rules/data/managed_rule_set.dart';

void main() {
  const normalizer = ManagedRuleSetNormalizer();
  final generatedAt = DateTime.utc(2026, 7, 30);
  final expiresAt = DateTime.utc(2026, 8, 30);

  Future<ManagedRuleSet> build({
    String id = 'ru-direct-core',
    List<String> domains = const ['example.ru'],
    List<String> cidrs = const ['192.0.2.0/24'],
    ManagedRuleAction action = ManagedRuleAction.direct,
    int priority = 100,
  }) {
    return normalizer.compile(
      id: id,
      version: '1',
      source: 'pinned:test',
      generatedAt: generatedAt,
      expiresAt: expiresAt,
      priority: priority,
      action: action,
      applicablePreset: ManagedRulePreset.russia,
      domainInput: domains,
      cidrInput: cidrs,
    );
  }

  test('normalizes schemes paths wildcards case and duplicates', () async {
    final result = await build(
      domains: ['HTTPS://API.EXAMPLE.RU/path', '||api.example.ru^', '*.static.example.ru', '.STATIC.EXAMPLE.RU.'],
    );
    expect(result.domainSuffixes, ['api.example.ru', 'static.example.ru']);
    expect(result.metadata.domainCount, 2);
  });

  test('accepts IDN unicode and canonical punycode forms', () {
    expect(normalizer.normalizeDomain('ПРИМЕР.РФ'), 'пример.рф');
    expect(normalizer.normalizeDomain('XN--E1AFMKFD.XN--P1AI'), 'xn--e1afmkfd.xn--p1ai');
  });

  test('normalizes IPv4 and IPv6 CIDRs', () async {
    final result = await build(cidrs: ['192.0.2.1/24', '2001:db8::1/48']);
    expect(result.ipCidrs, containsAll(['192.0.2.1/24', '2001:db8::1/48']));
  });

  test('rejects malformed domain and CIDR entries', () {
    expect(() => normalizer.normalizeDomain('https:///broken'), throwsA(isA<RuleSetValidationException>()));
    expect(() => normalizer.normalizeCidr('192.0.2.0/99'), throwsA(isA<RuleSetValidationException>()));
    expect(() => normalizer.normalizeCidr('not-an-ip/24'), throwsA(isA<RuleSetValidationException>()));
  });

  test('empty and comment-only input produces an empty list', () async {
    final result = await build(domains: ['', '# comment'], cidrs: ['; comment']);
    expect(result.domainSuffixes, isEmpty);
    expect(result.ipCidrs, isEmpty);
  });

  test('checksum is stable for normalized order', () async {
    final first = await build(domains: ['b.ru', 'a.ru']);
    final second = await build(domains: ['a.ru', 'b.ru']);
    expect(first.metadata.checksum, second.metadata.checksum);
  });

  test('atomic install and offline startup use last-known-good', () async {
    final directory = await Directory.systemTemp.createTemp('zeon-rules-');
    addTearDown(() => directory.delete(recursive: true));
    final store = ManagedRuleSetStore(directory: directory, now: () => generatedAt);
    final value = await build();
    await store.install(value);
    final cached = await store.readLastKnownGood(value.metadata.id);
    expect(cached?.metadata.checksum, value.metadata.checksum);
  });

  test('checksum mismatch rejects update and preserves last-known-good', () async {
    final directory = await Directory.systemTemp.createTemp('zeon-rules-');
    addTearDown(() => directory.delete(recursive: true));
    final store = ManagedRuleSetStore(directory: directory, now: () => generatedAt);
    final original = await build();
    await store.install(original);
    final tampered = original.toJson();
    (tampered['payload'] as Map<String, Object?>)['domainSuffix'] = ['other.ru'];
    await expectLater(
      store.update(original.metadata.id, () async => jsonEncode(tampered)),
      throwsA(isA<RuleSetValidationException>()),
    );
    expect((await store.readLastKnownGood(original.metadata.id))?.metadata.checksum, original.metadata.checksum);
  });

  test('stale update rejects and preserves last-known-good', () async {
    final directory = await Directory.systemTemp.createTemp('zeon-rules-');
    addTearDown(() => directory.delete(recursive: true));
    final store = ManagedRuleSetStore(directory: directory, now: () => expiresAt.add(const Duration(days: 1)));
    final stale = await build();
    await expectLater(store.install(stale), throwsA(isA<RuleSetValidationException>()));
    expect(await store.readLastKnownGood(stale.metadata.id), isNull);
  });

  test('API unavailable keeps last-known-good', () async {
    final directory = await Directory.systemTemp.createTemp('zeon-rules-');
    addTearDown(() => directory.delete(recursive: true));
    final store = ManagedRuleSetStore(directory: directory, now: () => generatedAt);
    final original = await build();
    await store.install(original);
    await expectLater(
      store.update(original.metadata.id, () => throw const SocketException('offline')),
      throwsA(isA<SocketException>()),
    );
    expect((await store.readLastKnownGood(original.metadata.id))?.metadata.version, '1');
  });

  test('id mismatch cannot replace a cached category', () async {
    final directory = await Directory.systemTemp.createTemp('zeon-rules-');
    addTearDown(() => directory.delete(recursive: true));
    final store = ManagedRuleSetStore(directory: directory, now: () => generatedAt);
    final candidate = await build(id: 'global-vpn-blocked');
    await expectLater(
      store.update('ru-direct-core', () async => jsonEncode(candidate.toJson())),
      throwsA(isA<RuleSetValidationException>()),
    );
  });

  test('domain and CIDR conflicts have deterministic priority', () async {
    final override = await build(
      id: 'user-overrides',
      domains: ['service.ru'],
      action: ManagedRuleAction.vpn,
      priority: 0,
    );
    final preset = await build(
      domains: ['service.ru'],
      cidrs: ['198.51.100.0/24'],
      action: ManagedRuleAction.direct,
      priority: 100,
    );
    final conflicts = detectRuleConflicts([preset, override]);
    expect(conflicts, hasLength(1));
    expect(conflicts.single.winner.metadata.id, 'user-overrides');
    expect(conflicts.single.loser.metadata.id, 'ru-direct-core');
  });

  test('metadata roundtrip keeps action separate from match data', () async {
    final value = await build(action: ManagedRuleAction.block);
    final restored = ManagedRuleSet.fromJson(jsonDecode(jsonEncode(value.toJson())) as Map<String, dynamic>);
    expect(restored.metadata.action, ManagedRuleAction.block);
    expect(restored.domainSuffixes, ['example.ru']);
  });

  test('truncated JSON update is rejected', () async {
    final directory = await Directory.systemTemp.createTemp('zeon-rules-');
    addTearDown(() => directory.delete(recursive: true));
    final store = ManagedRuleSetStore(directory: directory, now: () => generatedAt);
    await expectLater(
      store.update('ru-direct-core', () async => utf8.decode(Uint8List.fromList('{'.codeUnits))),
      throwsA(anything),
    );
  });
}
