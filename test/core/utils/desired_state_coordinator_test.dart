import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/utils/desired_state_coordinator.dart';

void main() {
  test('reconciles the latest state when it changes during an in-flight apply', () async {
    final firstApply = Completer<void>();
    final applied = <bool>[];
    late final DesiredStateCoordinator<bool> coordinator;
    coordinator = DesiredStateCoordinator<bool>(
      initialState: false,
      apply: (desired, generation) async {
        applied.add(desired);
        if (applied.length == 1) await firstApply.future;
        expect(coordinator.isCurrent(generation, desired), applied.length > 1);
      },
    );

    final firstRequest = coordinator.setDesiredState(true);
    final pauseRequest = coordinator.setDesiredState(false);
    final latestResumeRequest = coordinator.setDesiredState(true);

    firstApply.complete();
    await Future.wait([firstRequest, pauseRequest, latestResumeRequest]);

    expect(applied, [true, true]);
    expect(coordinator.desiredState, isTrue);
  });

  test('applies a pause that remains the latest request', () async {
    final firstApply = Completer<void>();
    final applied = <bool>[];
    final coordinator = DesiredStateCoordinator<bool>(
      initialState: false,
      apply: (desired, _) async {
        applied.add(desired);
        if (applied.length == 1) await firstApply.future;
      },
    );

    final resumeRequest = coordinator.setDesiredState(true);
    final pauseRequest = coordinator.setDesiredState(false);
    firstApply.complete();

    await Future.wait([resumeRequest, pauseRequest]);
    expect(applied, [true, false]);
    expect(coordinator.desiredState, isFalse);
  });

  test('a request made after completion starts a new reconciliation', () async {
    final applied = <bool>[];
    final coordinator = DesiredStateCoordinator<bool>(
      initialState: false,
      apply: (desired, _) async => applied.add(desired),
    );

    await coordinator.setDesiredState(true);
    await coordinator.setDesiredState(false);

    expect(applied, [true, false]);
  });

  test('a failed superseded operation does not lose the latest request', () async {
    final firstApply = Completer<void>();
    final applied = <bool>[];
    final coordinator = DesiredStateCoordinator<bool>(
      initialState: false,
      apply: (desired, _) async {
        applied.add(desired);
        if (applied.length == 1) {
          await firstApply.future;
          throw StateError('superseded close failed');
        }
      },
    );

    final pauseRequest = coordinator.setDesiredState(false);
    final resumeRequest = coordinator.setDesiredState(true);
    firstApply.complete();

    await Future.wait([pauseRequest, resumeRequest]);
    expect(applied, [false, true]);
    expect(coordinator.desiredState, isTrue);
  });

  test('a current failure is surfaced and a later request can retry', () async {
    var attempts = 0;
    final coordinator = DesiredStateCoordinator<bool>(
      initialState: false,
      apply: (_, _) async {
        attempts++;
        if (attempts == 1) throw StateError('setup failed');
      },
    );

    await expectLater(coordinator.setDesiredState(true), throwsStateError);
    await coordinator.setDesiredState(true);

    expect(attempts, 2);
    expect(coordinator.desiredState, isTrue);
  });
}
