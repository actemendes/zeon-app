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
          expect(options.s02Cycles, 1);
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
    await reporter.writeResult();

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

  test('seals terminal events before the awaited result write', () async {
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
    await reporter.writeResult();

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
    expect(source, contains('await reporter.writeResult()'));
    expect(source.indexOf('await reporter.writeResult()'), lessThan(source.lastIndexOf('exit(verdict.exitCode)')));
  });

  test('runtime result converts protobuf int64 values before JSON encoding', () async {
    final source = await File('tool/windows_recovery_runtime.dart').readAsString();
    expect(source, contains("'memory_bytes': info.memory.toInt()"));
    expect(source, isNot(contains("'memory_bytes': info.memory,")));
  });

  test('system-proxy verification uses the test principal WinINet profile', () async {
    final source = await File('tool/windows_recovery_runtime.dart').readAsString();
    expect(source, contains('HarnessMode.systemProxy => await _fetchWithSystemProxy(target)'));
    expect(source, contains('[Net.WebRequest]::DefaultWebProxy.GetProxy'));
    expect(source, contains('[Net.HttpWebRequest]::Create'));
    expect(source, contains('Proxy=[Net.WebRequest]::DefaultWebProxy'));
    expect(source, contains('ZEON_RUNTIME_TRAFFIC_TARGET'));
    expect(source, contains('includeParentEnvironment: false'));
    expect(source, isNot(contains("target.toString(),\n      '\${options.proxyPort}',")));
    expect(source, isNot(contains("'--proxy',")));
    expect(source, contains("reporter.event('outbound_selected'"));
    expect(source, contains("RuntimeFailure.deadline('concrete outbound readiness'"));
    expect(source, contains("'runtime_leaf_id':"));
    expect(source, contains("'exit_code': error.errorCode"));
    expect(source, contains("43 => 'system_proxy_web_request'"));
    expect(source, contains("'signal': 'product-health'"));
    expect(source, contains("'win32_code': error.win32Code"));
  });

  test('S06 observes the late-start window and then proves retry traffic and stop', () async {
    final source = await File('tool/windows_recovery_runtime.dart').readAsString();
    final observation = source.indexOf("reporter.event('s06_no_late_activation'");
    final retry = source.indexOf("reporter.event('s06_retry_passed'");
    expect(observation, greaterThan(0));
    expect(retry, greaterThan(observation));
    expect(source.substring(observation, retry), contains('await _connectAndProveReady()'));
    expect(source.substring(observation, retry), contains('await _verifyTraffic(verifyProductHealth: false)'));
    expect(source.substring(observation, retry), contains("await _disconnectAndVerify('s06-retry')"));
  });

  test('S02 proves traffic, direct internet, reconnect, and final stop', () async {
    final source = await File('tool/windows_recovery_runtime.dart').readAsString();
    final scenarioStart = source.indexOf('Future<void> _scenarioS02()');
    final scenarioEnd = source.indexOf('Future<void> _scenarioS06()', scenarioStart);
    final scenario = source.substring(scenarioStart, scenarioEnd);
    final ready = scenario.indexOf('await _connectAndProveReady()');
    final outbound = scenario.indexOf('await _reportSelectedOutbound()');
    final traffic = scenario.indexOf('await _verifyTraffic(verifyProductHealth: false)');
    final firstStop = scenario.indexOf("await _disconnectAndVerify('s02-cycle-\$cycle-first-stop')");
    final direct = scenario.indexOf('await _verifyDirectTraffic(cycle)');
    final reconnect = scenario.indexOf('await _connectAndProveReady()', direct);
    final secondTraffic = scenario.indexOf('await _verifyTraffic(verifyProductHealth: false)', reconnect);
    final finalStop = scenario.indexOf("await _disconnectAndVerify('s02-cycle-\$cycle-final-stop')");
    expect(ready, greaterThanOrEqualTo(0));
    expect(outbound, greaterThan(ready));
    expect(traffic, greaterThan(outbound));
    expect(firstStop, greaterThan(traffic));
    expect(direct, greaterThan(firstStop));
    expect(reconnect, greaterThan(direct));
    expect(secondTraffic, greaterThan(reconnect));
    expect(finalStop, greaterThan(secondTraffic));
    expect(source, contains("reporter.event('s02_direct_internet_verified'"));
    expect(source, contains("'route': 'direct-after-disconnect'"));
    expect(source, contains("'product_health_checked': verifyProductHealth"));
  });

  test('Auto scenario follows exact R08 order and proves post-Auto traffic', () async {
    final source = await File('tool/windows_recovery_runtime.dart').readAsString();
    final scenarioStart = source.indexOf('Future<void> _scenarioAutoProxy()');
    final scenarioEnd = source.indexOf('Future<OutboundInfo?> _verifyNativeSelection(', scenarioStart);
    final scenario = source.substring(scenarioStart, scenarioEnd);
    final manualChoice = scenario.indexOf('changeProxy(group.tag, manual.tag)');
    final initialTraffic = scenario.indexOf('await _verifyTraffic()', manualChoice);
    final stop = scenario.indexOf("await _disconnectAndVerify('auto-proxy-manual-stage')", initialTraffic);
    final reconnect = scenario.indexOf('await _connectAndProveReady()', stop);
    final reconnectManualProof = scenario.indexOf(
      'await _verifyNativeSelection(group.tag, manual.tag, requireConcreteLeaf: false)',
      reconnect,
    );
    final autoChoice = scenario.indexOf('changeProxy(group.tag, auto.tag)', reconnectManualProof);
    final autoSelectorProof = scenario.indexOf('await _verifyNativeSelectorTag(group.tag, auto.tag)', autoChoice);
    final postAutoTraffic = scenario.indexOf('await _verifyTraffic()', autoSelectorProof);
    final autoLeafProof = scenario.indexOf('await _waitForConcreteNativeLeaf(group.tag, auto.tag)', postAutoTraffic);
    expect(manualChoice, greaterThanOrEqualTo(0));
    expect(initialTraffic, greaterThan(manualChoice));
    expect(stop, greaterThan(initialTraffic));
    expect(reconnect, greaterThan(stop));
    expect(reconnectManualProof, greaterThan(reconnect));
    expect(autoChoice, greaterThan(reconnectManualProof));
    expect(autoSelectorProof, greaterThan(autoChoice));
    expect(postAutoTraffic, greaterThan(autoSelectorProof));
    expect(autoLeafProof, greaterThan(postAutoTraffic));
    expect(scenario, contains("'exact_r08_order': true"));
  });

  test('P03 R17 scenario proves refresh ownership, restart, and post-refresh Auto traffic', () async {
    final source = await File('tool/windows_recovery_runtime.dart').readAsString();
    final scenarioStart = source.indexOf('Future<void> _scenarioP03R17()');
    final scenarioEnd = source.indexOf('Future<OutboundInfo?> _verifyNativeSelection(', scenarioStart);
    final scenario = source.substring(scenarioStart, scenarioEnd);
    final dataChecks = scenario.indexOf('validation.runDataAndErrorChecks()');
    final disconnectedRefresh = scenario.indexOf('validation.refreshActiveRemoteProfile()', dataChecks);
    final connect = scenario.indexOf('await _connectAndProveReady()', disconnectedRefresh);
    final manualChoice = scenario.indexOf('changeProxy(group.tag, manual.tag)', connect);
    final connectedRefresh = scenario.indexOf('validation.refreshActiveRemoteProfile()', manualChoice);
    final restartProof = scenario.indexOf("restartStates.contains('CoreStopping')", connectedRefresh);
    final autoChoice = scenario.indexOf('changeProxy(group.tag, refreshedAuto.tag)', restartProof);
    final postAutoTraffic = scenario.indexOf('await _verifyTraffic()', autoChoice);
    final concreteLeaf = scenario.indexOf(
      'await _waitForConcreteNativeLeaf(group.tag, refreshedAuto.tag)',
      postAutoTraffic,
    );
    final keyLoss = scenario.indexOf('validation.runKeyLossCheckAndRestore()', concreteLeaf);
    expect(dataChecks, greaterThanOrEqualTo(0));
    expect(disconnectedRefresh, greaterThan(dataChecks));
    expect(connect, greaterThan(disconnectedRefresh));
    expect(manualChoice, greaterThan(connect));
    expect(connectedRefresh, greaterThan(manualChoice));
    expect(restartProof, greaterThan(connectedRefresh));
    expect(autoChoice, greaterThan(restartProof));
    expect(postAutoTraffic, greaterThan(autoChoice));
    expect(concreteLeaf, greaterThan(postAutoTraffic));
    expect(keyLoss, greaterThan(concreteLeaf));
    expect(source, contains('zeon.runtime-remote-profile-fixture.v1'));
    expect(source, contains("source.host.toLowerCase() != 'zeon-vps.link'"));
  });
}
