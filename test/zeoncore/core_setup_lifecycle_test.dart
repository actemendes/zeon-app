import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/model/directories.dart';
import 'package:zeon/zeoncore/core_interface/core_interface.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';

void main() {
  test('setup reuses a live foreground core initialized during bootstrap', () async {
    final core = _ActiveCoreInterface();
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final result = await container.read(provider).setup().run();

    expect(result.isRight(), isTrue);
    expect(core.healthChecks, 1);
    expect(core.setupCalls, 0);
  });

  test('concurrent setup calls share one foreground health probe', () async {
    final healthBarrier = Completer<bool>();
    final core = _ActiveCoreInterface(healthBarrier: healthBarrier);
    final provider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: core));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(provider);

    final first = service.setup().run();
    await Future<void>.delayed(Duration.zero);
    final second = service.setup().run();

    expect(core.healthChecks, 1);
    healthBarrier.complete(true);
    final results = await Future.wait([first, second]);

    expect(results.every((result) => result.isRight()), isTrue);
    expect(core.healthChecks, 1);
    expect(core.setupCalls, 0);
  });
}

class _ActiveCoreInterface extends CoreInterface {
  _ActiveCoreInterface({this.healthBarrier});

  final Completer<bool>? healthBarrier;
  int healthChecks = 0;
  int setupCalls = 0;

  @override
  bool isInitialized() => true;

  @override
  Future<bool> isActiveFg() {
    healthChecks++;
    return healthBarrier?.future ?? Future<bool>.value(true);
  }

  @override
  Future<String> setup(Directories directories, bool debug, int mode) async {
    setupCalls++;
    return '';
  }
}
