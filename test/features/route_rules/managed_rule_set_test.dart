import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/route_rules/data/managed_rule_set.dart';

void main() {
  const normalizer = ManagedRuleSetNormalizer();
  final generatedAt = DateTime.utc(2026, 7, 30);
  final expiresAt = DateTime.utc(2026, 8, 30);

  Future<ManagedRuleSet> build({
    String id = 'ru-direct-core',
    String version = '1',
    List<String> domains = const ['example.ru'],
    List<String> cidrs = const ['192.0.2.0/24'],
    ManagedRuleAction action = ManagedRuleAction.direct,
    int priority = 100,
  }) {
    return normalizer.compile(
      id: id,
      version: version,
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

  Future<ManagedRuleSetEnvelope> buildEnvelope({
    int generation = 1,
    List<ManagedRuleSet>? ruleSets,
    DateTime? bundleExpiresAt,
    Object? rawPayload,
  }) async {
    final payload = utf8.encode(
      rawPayload is String
          ? rawPayload
          : jsonEncode({
              'generatedAt': generatedAt.toIso8601String(),
              'expiresAt': (bundleExpiresAt ?? expiresAt).toIso8601String(),
              'ruleSets': (ruleSets ?? [await build()]).map((ruleSet) => ruleSet.toJson()).toList(),
            }),
    );
    final digest = await Sha256().hash(payload);
    final checksum = digest.bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return ManagedRuleSetEnvelope(
      formatVersion: 1,
      generation: generation,
      payload: base64Url.encode(payload).replaceAll('=', ''),
      checksum: checksum,
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
    (tampered['payload']! as Map<String, Object?>)['domainSuffix'] = ['other.ru'];
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
    final preset = await build(domains: ['service.ru'], cidrs: ['198.51.100.0/24']);
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

  test('bundle verifies exact payload hash before parsing JSON', () async {
    final directory = await Directory.systemTemp.createTemp('zeon-rules-');
    addTearDown(() => directory.delete(recursive: true));
    final store = ManagedRuleSetStore(directory: directory, now: () => generatedAt);
    final malformed = await buildEnvelope(rawPayload: '{');
    final tamperedChecksum = ManagedRuleSetEnvelope(
      formatVersion: malformed.formatVersion,
      generation: malformed.generation,
      payload: malformed.payload,
      checksum: '00${malformed.checksum.substring(2)}',
    );

    await expectLater(
      store.validateEnvelope(tamperedChecksum, rejectExpired: true),
      throwsA(
        isA<RuleSetValidationException>().having((error) => error.message, 'message', 'envelope checksum mismatch'),
      ),
    );
  });

  test('bundle accepts bootstrap generation zero and installs active.json', () async {
    final directory = await Directory.systemTemp.createTemp('zeon-rules-');
    addTearDown(() => directory.delete(recursive: true));
    final store = ManagedRuleSetStore(directory: directory, now: () => generatedAt);
    final empty = await build(domains: const [], cidrs: const []);
    final envelope = await buildEnvelope(generation: 0, ruleSets: [empty]);

    final installed = await store.installEnvelope(envelope);

    expect(installed.envelope.generation, 0);
    expect(await store.activeFile.exists(), isTrue);
    expect((await store.readActiveBundle())?.bundle.ruleSets.single.domainSuffixes, isEmpty);
  });

  test('invalid new bundle preserves active last-known-good', () async {
    final directory = await Directory.systemTemp.createTemp('zeon-rules-');
    addTearDown(() => directory.delete(recursive: true));
    final store = ManagedRuleSetStore(directory: directory, now: () => generatedAt);
    final active = await buildEnvelope();
    await store.installEnvelope(active);
    final expired = await buildEnvelope(
      generation: 2,
      bundleExpiresAt: generatedAt.subtract(const Duration(minutes: 1)),
    );

    await expectLater(store.installEnvelope(expired), throwsA(isA<RuleSetValidationException>()));

    expect((await store.readActiveBundle())?.envelope.generation, 1);
  });

  test('corrupt active file is atomically recovered from .lkg', () async {
    final directory = await Directory.systemTemp.createTemp('zeon-rules-');
    addTearDown(() => directory.delete(recursive: true));
    final store = ManagedRuleSetStore(directory: directory, now: () => generatedAt);
    await store.installEnvelope(await buildEnvelope());
    await store.installEnvelope(await buildEnvelope(generation: 2, ruleSets: [await build(version: '2')]));
    await store.activeFile.writeAsString('{', flush: true);

    final recovered = await store.readActiveBundle();

    expect(recovered?.envelope.generation, 1);
    expect(jsonDecode(await store.activeFile.readAsString()), isA<Map<String, dynamic>>());
  });

  test('bundle rejects cross-action conflicts', () async {
    final directory = await Directory.systemTemp.createTemp('zeon-rules-');
    addTearDown(() => directory.delete(recursive: true));
    final store = ManagedRuleSetStore(directory: directory, now: () => generatedAt);
    final direct = await build(domains: ['same.ru']);
    final vpn = await build(id: 'force-vpn', domains: ['same.ru'], action: ManagedRuleAction.vpn, priority: 1);

    await expectLater(
      store.validateEnvelope(await buildEnvelope(ruleSets: [direct, vpn]), rejectExpired: true),
      throwsA(isA<RuleSetValidationException>()),
    );
  });
}
