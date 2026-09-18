import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/features/connection/data/connection_repository.dart';
import 'package:zeon/features/profile/data/profile_config_store.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';

void main() {
  for (final action in ['connect', 'stop', 'none']) {
    test('launch preparation reserves before config IO and respects later $action', () async {
      final core = _Core();
      final store = _Store();
      final provider = Provider(
        (ref) => ConnectionRepositoryImpl(
          ref: ref,
          directories: (baseDir: Directory.systemTemp, workingDir: Directory.systemTemp, tempDir: Directory.systemTemp),
          singbox: core,
          configOptionRepository: _Options(),
          profileConfigStore: store,
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final operation = container
          .read(provider)
          .prepareSystemVpn(
            ProfileEntity.local(id: 'fixture', active: true, name: 'Fixture', lastUpdate: DateTime.utc(2026)),
            false,
          )
          .run();
      expect(core.generation, 1, reason: 'preparation must reserve before awaiting config');
      if (action != 'none') core.beginVpnOperation(action);
      store.readBarrier.complete('{}');
      expect((await operation).isRight(), isTrue);
      expect(core.prepared, action == 'none' ? [1] : isEmpty);
      expect(core.generation, action == 'none' ? 1 : 2);
    });
  }
}

class _Core implements ZeonCoreService {
  int generation = 0;
  final prepared = <int>[];
  @override
  int beginVpnOperation(String source) => ++generation;
  @override
  bool isVpnOperationCurrent(int value, {String source = 'external_operation_guard'}) => value == generation;
  @override
  TaskEither<String, Unit> prepareVpnConfiguration(
    String path,
    String name,
    bool disableMemoryLimit, {
    required int generation,
  }) {
    prepared.add(generation);
    return TaskEither.of(unit);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Store implements ProfileConfigStore {
  final readBarrier = Completer<String>();
  @override
  Future<String> read(String profileId) => readBarrier.future;
  @override
  Future<File> createRuntimeConnectionFile(String profileId, {String? content}) async => File('/unused-fixture');
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Options implements ConfigOptionRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
