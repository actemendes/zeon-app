import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/features/route_rules/data/managed_rule_set.dart';
import 'package:zeon/features/route_rules/data/managed_rule_set_sync.dart';

void main() {
  final generatedAt = DateTime.utc(2026, 7, 31);
  final expiresAt = DateTime.utc(2026, 8, 31);

  Future<ManagedRuleSetEnvelope> envelope(int generation) async {
    final ruleSet = await const ManagedRuleSetNormalizer().compile(
      id: 'force-vpn',
      version: '$generation',
      source: 'test',
      generatedAt: generatedAt,
      expiresAt: expiresAt,
      priority: 1,
      action: ManagedRuleAction.vpn,
      applicablePreset: ManagedRulePreset.russia,
      domainInput: ['blocked.ru'],
      cidrInput: const [],
    );
    final payloadBytes = utf8.encode(
      jsonEncode({
        'generatedAt': generatedAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
        'ruleSets': [ruleSet.toJson()],
      }),
    );
    final digest = await Sha256().hash(payloadBytes);
    return ManagedRuleSetEnvelope(
      formatVersion: 1,
      generation: generation,
      payload: base64Url.encode(payloadBytes).replaceAll('=', ''),
      checksum: digest.bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
    );
  }

  Future<({Directory directory, ManagedRuleSetStore store, SharedPreferences preferences})> dependencies() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final directory = await Directory.systemTemp.createTemp('zeon-managed-sync-');
    addTearDown(() => directory.delete(recursive: true));
    return (
      directory: directory,
      store: ManagedRuleSetStore(directory: directory, now: () => generatedAt),
      preferences: preferences,
    );
  }

  test('API parser accepts bare envelope and legacy ok/data wrapper', () async {
    final value = await envelope(1);

    expect(parseManagedRuleSetApiBody(value.toJson()).generation, 1);
    expect(parseManagedRuleSetApiBody({'ok': true, 'data': value.toJson()}).checksum, value.checksum);
  });

  test('fresh successful check observes the 24 hour TTL', () async {
    final deps = await dependencies();
    final active = await envelope(1);
    await deps.store.installEnvelope(active);
    await deps.preferences.setString(ManagedRuleSetSyncService.lastSuccessfulCheckKey, generatedAt.toIso8601String());
    await deps.preferences.setInt(ManagedRuleSetSyncService.activeGenerationKey, active.generation);
    await deps.preferences.setString(ManagedRuleSetSyncService.activeChecksumKey, active.checksum);
    final remote = _FakeRemote((_) async => throw StateError('network must not be called'));
    final service = ManagedRuleSetSyncService(
      remoteDataSource: remote,
      store: deps.store,
      preferences: deps.preferences,
      now: () => generatedAt.add(const Duration(hours: 23)),
    );

    expect(await service.sync(reason: 'ttl_test'), ManagedRuleSetSyncResult.skipped);
    expect(remote.calls, 0);
  });

  test('conditional 304 refreshes TTL without replacing active bundle', () async {
    final deps = await dependencies();
    final active = await envelope(1);
    await deps.store.installEnvelope(active);
    await deps.preferences.setString(ManagedRuleSetSyncService.eTagKey, '"generation-1"');
    await deps.preferences.setInt(ManagedRuleSetSyncService.activeGenerationKey, active.generation);
    await deps.preferences.setString(ManagedRuleSetSyncService.activeChecksumKey, active.checksum);
    var published = false;
    final next = await envelope(2);
    final remote = _FakeRemote(
      (_) async => published
          ? ManagedRuleSetFetchResult.modified(next, eTag: '"generation-2"')
          : ManagedRuleSetFetchResult.notModified(eTag: '"generation-1"'),
    );
    final checkedAt = generatedAt.add(const Duration(hours: 2));
    final service = ManagedRuleSetSyncService(
      remoteDataSource: remote,
      store: deps.store,
      preferences: deps.preferences,
      now: () => checkedAt,
    );

    expect(await service.sync(force: true, reason: 'subscription_refresh'), ManagedRuleSetSyncResult.notModified);
    expect(remote.eTags, ['"generation-1"']);
    expect(deps.preferences.getString(ManagedRuleSetSyncService.lastSuccessfulCheckKey), checkedAt.toIso8601String());
    expect((await deps.store.readActiveBundle())?.envelope.generation, 1);

    published = true;
    expect(await service.sync(force: true, reason: 'next_profile'), ManagedRuleSetSyncResult.updated);
    expect(remote.calls, 2);
    expect((await deps.store.readActiveBundle())?.envelope.generation, 2);
  });

  test('concurrent checks share one in-flight request', () async {
    final deps = await dependencies();
    final response = Completer<ManagedRuleSetFetchResult>();
    final remote = _FakeRemote((_) => response.future);
    final service = ManagedRuleSetSyncService(
      remoteDataSource: remote,
      store: deps.store,
      preferences: deps.preferences,
      now: () => generatedAt,
    );

    final first = service.sync(force: true, reason: 'first');
    final second = service.sync(force: true, reason: 'second');
    expect(identical(first, second), isTrue);
    for (var attempt = 0; attempt < 20 && remote.calls == 0; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(remote.calls, 1);

    response.complete(ManagedRuleSetFetchResult.modified(await envelope(1), eTag: '"generation-1"'));
    expect(await first, ManagedRuleSetSyncResult.updated);
    expect(await second, ManagedRuleSetSyncResult.updated);
  });

  test('forced refresh queues behind a TTL-governed in-flight check', () async {
    final deps = await dependencies();
    final active = await envelope(1);
    await deps.store.installEnvelope(active);
    await deps.preferences.setString(ManagedRuleSetSyncService.lastSuccessfulCheckKey, generatedAt.toIso8601String());
    await deps.preferences.setInt(ManagedRuleSetSyncService.activeGenerationKey, active.generation);
    await deps.preferences.setString(ManagedRuleSetSyncService.activeChecksumKey, active.checksum);
    final next = await envelope(2);
    final remote = _FakeRemote((_) async => ManagedRuleSetFetchResult.modified(next, eTag: '"generation-2"'));
    final service = ManagedRuleSetSyncService(
      remoteDataSource: remote,
      store: deps.store,
      preferences: deps.preferences,
      now: () => generatedAt.add(const Duration(hours: 1)),
    );

    final background = service.sync(reason: 'config_generation');
    final forced = service.sync(force: true, reason: 'subscription_refresh');

    expect(await background, ManagedRuleSetSyncResult.skipped);
    expect(await forced, ManagedRuleSetSyncResult.updated);
    expect(remote.calls, 1);
    expect((await deps.store.readActiveBundle())?.envelope.generation, 2);
  });

  test('network failure is swallowed and preserves active LKG', () async {
    final deps = await dependencies();
    await deps.store.installEnvelope(await envelope(1));
    final remote = _FakeRemote((_) async => throw const SocketException('offline'));
    final service = ManagedRuleSetSyncService(
      remoteDataSource: remote,
      store: deps.store,
      preferences: deps.preferences,
      now: () => generatedAt.add(const Duration(hours: 1)),
    );

    expect(await service.sync(force: true, reason: 'offline'), ManagedRuleSetSyncResult.failed);
    expect((await deps.store.readActiveBundle())?.envelope.generation, 1);
  });

  test('LKG recovery never sends the newer generation ETag', () async {
    final deps = await dependencies();
    final first = await envelope(1);
    final second = await envelope(2);
    await deps.store.installEnvelope(first);
    await deps.store.installEnvelope(second);
    await deps.preferences.setString(ManagedRuleSetSyncService.eTagKey, '"generation-2"');
    await deps.preferences.setInt(ManagedRuleSetSyncService.activeGenerationKey, second.generation);
    await deps.preferences.setString(ManagedRuleSetSyncService.activeChecksumKey, second.checksum);
    await deps.preferences.setString(ManagedRuleSetSyncService.lastSuccessfulCheckKey, generatedAt.toIso8601String());
    await deps.store.activeFile.writeAsString('{', flush: true);

    final remote = _FakeRemote((_) async => ManagedRuleSetFetchResult.modified(second, eTag: '"generation-2"'));
    final service = ManagedRuleSetSyncService(
      remoteDataSource: remote,
      store: deps.store,
      preferences: deps.preferences,
      now: () => generatedAt.add(const Duration(hours: 1)),
    );

    expect(await service.sync(reason: 'recovery'), ManagedRuleSetSyncResult.updated);
    expect(remote.eTags, [isNull]);
    expect((await deps.store.readActiveBundle())?.envelope.generation, 2);
  });
}

class _FakeRemote implements ManagedRuleSetRemoteDataSource {
  _FakeRemote(this._handler);

  final Future<ManagedRuleSetFetchResult> Function(String? eTag) _handler;
  int calls = 0;
  final List<String?> eTags = [];

  @override
  Future<ManagedRuleSetFetchResult> fetch({String? eTag}) {
    calls += 1;
    eTags.add(eTag);
    return _handler(eTag);
  }
}
