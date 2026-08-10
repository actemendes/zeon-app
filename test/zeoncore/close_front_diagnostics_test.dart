import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/zeoncore/core_interface/core_interface.dart';
import 'package:zeon/zeoncore/core_interface/core_interface_mobile.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';

void main() {
  group('closeFront current decision semantics', () {
    test('connected background probe selects Started', () {
      expect(closeFrontStatusForBackgroundProbe(true), const CoreStatus.started());
    });

    test('false background probe selects Stopped', () {
      expect(closeFrontStatusForBackgroundProbe(false), const CoreStatus.stopped());
    });

    test('a stale closeFront can overwrite Started published by resume setup', () async {
      final probeResult = Completer<bool>();
      final timeline = <String>[];
      CoreStatus currentStatus = const CoreStatus.started();

      final closeOperation = () async {
        timeline.add('close_enter');
        final backgroundActive = await probeResult.future;
        timeline.add('close_probe_complete');
        currentStatus = closeFrontStatusForBackgroundProbe(backgroundActive);
        timeline.add('close_publish_stopped');
      }();

      timeline.add('resume_setup_publish_started');
      currentStatus = const CoreStatus.started();
      probeResult.complete(false);
      await closeOperation;

      expect(timeline, const [
        'close_enter',
        'resume_setup_publish_started',
        'close_probe_complete',
        'close_publish_stopped',
      ]);
      expect(currentStatus, const CoreStatus.stopped());
    });
  });

  group('mobile background port probe diagnostics', () {
    test('the probe that determines true emits one connected observation', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var acceptedConnections = 0;
      final accepted = Completer<void>();
      final subscription = server.listen((socket) async {
        acceptedConnections++;
        await socket.close();
        if (!accepted.isCompleted) accepted.complete();
      });
      PortProbeObservation? observation;

      try {
        final active = await isPortOpen(
          InternetAddress.loopbackIPv4.address,
          server.port,
          onObservation: (value) => observation = value,
        );
        await accepted.future.timeout(const Duration(seconds: 1));

        expect(active, isTrue);
        expect(acceptedConnections, 1);
        expect(observation?.outcome, PortProbeOutcome.connected);
        expect(closeFrontStatusForBackgroundProbe(active), const CoreStatus.started());
      } finally {
        await subscription.cancel();
        await server.close();
      }
    });

    test('connection refused is categorized as closed without exposing its message', () {
      const error = SocketException('environment-specific text', osError: OSError('refused', 111));

      expect(classifySocketProbeError(error), PortProbeOutcome.closed);
    });

    test('timeout socket codes remain distinct from other socket errors', () {
      const timeout = SocketException('opaque', osError: OSError('timeout', 110));
      const other = SocketException('opaque', osError: OSError('other', 12345));

      expect(classifySocketProbeError(timeout), PortProbeOutcome.timeout);
      expect(classifySocketProbeError(other), PortProbeOutcome.socketError);
    });
  });
}
