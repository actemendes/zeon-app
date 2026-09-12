import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';

import '../../tool/windows_recovery_runtime.dart';

void main() {
  group('Windows runtime options', () {
    test('parses every scenario and public mode name', () {
      for (final scenario in RuntimeScenario.values) {
        for (final mode in HarnessMode.values) {
          final options = RuntimeOptions.parse([
            '--scenario',
            scenario.cliName,
            '--mode=${mode.cliName}',
            '--evidence-dir',
            r'C:\evidence',
            '--profile-file',
            r'C:\fixture.txt',
            '--run-id',
            'preflight-001',
          ], environment: const {});

          expect(options.scenario, scenario);
          expect(options.mode, mode);
          expect(options.connectTimeout, const Duration(seconds: 45));
          expect(options.toJson()['timeouts_seconds'], containsPair('s06_late_activation_observation', 150));
        }
      }
    });

    test('maps public mode names to application service modes', () {
      expect(HarnessMode.parse('system-proxy').serviceMode, ServiceMode.systemProxy);
      expect(HarnessMode.parse('tun').serviceMode, ServiceMode.tun);
      expect(HarnessMode.parse('local-proxy').serviceMode, ServiceMode.proxy);
    });

    test('allows preflight without a profile and requires one for connect', () {
      final preflight = RuntimeOptions.parse([
        '--scenario',
        'preflight',
        '--mode',
        'system-proxy',
        '--evidence-dir',
        r'C:\evidence',
        '--run-id',
        'preflight-remote-001',
      ], environment: const {});

      expect(preflight.scenario, RuntimeScenario.preflight);
      expect(preflight.profileFile, isNull);
      expect(
        () => RuntimeOptions.parse([
          '--scenario',
          'connect',
          '--evidence-dir',
          r'C:\evidence',
          '--run-id',
          'connect-no-fixture',
        ], environment: const {}),
        throwsFormatException,
      );
    });

    test('accepts environment configuration and repeated HTTPS targets', () {
      final options = RuntimeOptions.parse(
        const [],
        environment: const {
          'ZEON_RUNTIME_SCENARIO': 's02',
          'ZEON_RUNTIME_MODE': 'tun',
          'ZEON_RUNTIME_EVIDENCE_DIR': r'C:\evidence',
          'ZEON_RUNTIME_PROFILE_FILE': r'C:\fixture.txt',
          'ZEON_RUNTIME_RUN_ID': 's02-env-001',
          'ZEON_RUNTIME_TRAFFIC_URLS': 'https://example.com/a,https://example.org/b',
          'ZEON_RUNTIME_S02_CYCLES': '3',
        },
      );

      expect(options.scenario, RuntimeScenario.s02);
      expect(options.mode, HarnessMode.tun);
      expect(options.s02Cycles, 3);
      expect(options.trafficUrls, hasLength(2));
    });

    test('refuses to relax the 45 second connection contract', () {
      expect(
        () => RuntimeOptions.parse([
          '--evidence-dir',
          r'C:\evidence',
          '--profile-file',
          r'C:\fixture.txt',
          '--run-id',
          'invalid-001',
          '--connect-timeout-seconds',
          '46',
        ], environment: const {}),
        throwsFormatException,
      );
    });

    test('rejects unknown options and non-HTTPS traffic', () {
      expect(
        () => RuntimeOptions.parse([
          '--evidence-dir',
          r'C:\evidence',
          '--profile-file',
          r'C:\fixture.txt',
          '--run-id',
          'invalid-002',
          '--unknown',
          'value',
        ], environment: const {}),
        throwsFormatException,
      );
      expect(
        () => RuntimeOptions.parse([
          '--evidence-dir',
          r'C:\evidence',
          '--profile-file',
          r'C:\fixture.txt',
          '--run-id',
          'invalid-003',
          '--traffic-url',
          'http://example.com',
          '--traffic-url',
          'https://example.org',
        ], environment: const {}),
        throwsFormatException,
      );
    });
  });

  test('writes the stable machine-readable result and event schemas', () async {
    final directory = await Directory.systemTemp.createTemp('zeon-runtime-report-');
    addTearDown(() => directory.delete(recursive: true));
    final options = RuntimeOptions.parse([
      '--scenario',
      's06',
      '--mode',
      'tun',
      '--evidence-dir',
      directory.path,
      '--profile-file',
      r'C:\fixture.txt',
      '--run-id',
      'schema-001',
    ], environment: const {});
    final reporter = HarnessReporter(options, directory)
      ..machine = 'ZEON-W10-LAB'
      ..appVersion = '1.5.0'
      ..buildNumber = '1'
      ..verdict = RuntimeVerdict.fail
      ..reason = 'fixture verdict';
    reporter.cleanupAttempts.add({'verified': true});
    reporter.addEvidence(reporter.eventsFile.path);
    await reporter.event('schema_probe');
    reporter.writeResultSync();

    final result = jsonDecode(await reporter.resultFile.readAsString()) as Map<String, dynamic>;
    expect(result['schema'], 'zeon.windows-runtime.v1');
    expect(result, containsPair('verdict', 'FAIL'));
    expect(
      result.keys,
      containsAll(<String>[
        'application',
        'machine',
        'mode',
        'scenario',
        'phase_timestamps',
        'application_state',
        'native_core_state',
        'network_traffic',
        'cleanup',
        'evidence_paths',
      ]),
    );
    expect((result['cleanup'] as Map<String, dynamic>)['verified'], isTrue);
    final event = jsonDecode((await reporter.eventsFile.readAsLines()).single) as Map<String, dynamic>;
    expect(event, containsPair('event', 'schema_probe'));
    expect(event, containsPair('run_id', 'schema-001'));
  });

  test('seals terminal events before the synchronous result write', () async {
    final directory = await Directory.systemTemp.createTemp('zeon-runtime-seal-');
    addTearDown(() => directory.delete(recursive: true));
    final options = RuntimeOptions.parse([
      '--scenario',
      'preflight',
      '--mode',
      'system-proxy',
      '--evidence-dir',
      directory.path,
      '--run-id',
      'seal-001',
    ], environment: const {});
    final reporter = HarnessReporter(options, directory);

    await reporter.event('before_seal');
    await reporter.sealEvents();
    await reporter.event('must_be_ignored');
    reporter.writeResultSync();

    final events = await reporter.eventsFile.readAsLines();
    expect(events, hasLength(2));
    expect(jsonDecode(events.first), containsPair('event', 'before_seal'));
    expect(jsonDecode(events.last), containsPair('event', 'event_stream_sealed'));
    expect(await reporter.resultFile.exists(), isTrue);
  });

  test('runtime source cannot block on provider disposal after strict cleanup', () async {
    final source = await File('tool/windows_recovery_runtime.dart').readAsString();
    expect(source, contains("'provider_teardown': 'process_exit'"));
    expect(source, isNot(contains('await harness.dispose()')));
    expect(source, isNot(contains('coreSubscription?.cancel()')));
    expect(source, isNot(contains('appSubscription?.close()')));
    expect(source, isNot(contains('proxyKeepAlive?.close()')));
    expect(source, isNot(contains('container?.dispose()')));
    expect(source, contains('await reporter.sealEvents()'));
    expect(source, contains('reporter.writeResultSync()'));
    expect(source.indexOf('reporter.writeResultSync()'), lessThan(source.lastIndexOf('exit(verdict.exitCode)')));
  });
}
