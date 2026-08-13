import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/logger/logger_controller.dart';
import 'package:zeon/core/model/app_info_entity.dart';
import 'package:zeon/core/model/environment.dart';
import 'package:zeon/features/diagnostics/data/error_report_controller.dart';
import 'package:zeon/features/diagnostics/data/error_report_queue.dart';
import 'package:zeon/features/diagnostics/data/error_report_sender.dart';
import 'package:zeon/features/log/data/log_path_resolver.dart';
import 'package:zeon/features/mobile/data/stable_device_id_service.dart';
import 'package:zeon/utils/custom_loggers.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('dispose prevents detached initial maintenance from mutating state', () async {
    SharedPreferences.setMockInitialValues({'started_by_user': true, 'mobile_auto_import_device_id': 'test-device-id'});
    final preferences = await SharedPreferences.getInstance();
    final queue = ErrorReportQueue(preferences: preferences);
    await queue.enqueue({'event_id': 'queued-before-init', 'trigger': 'test'});

    final sender = _BlockingErrorReportSender();
    final tempDirectory = await Directory.systemTemp.createTemp('zeon-error-report-controller-');
    final coreServiceProvider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref));
    final container = ProviderContainer();
    final coreService = container.read(coreServiceProvider);
    LoggerController.init(p.join(tempDirectory.path, 'app.log'));

    final controller = ErrorReportController(
      appInfo: const AppInfoEntity(
        name: 'ZEON',
        version: '1.0.0',
        buildNumber: '1',
        release: Release.general,
        operatingSystem: 'test',
        operatingSystemVersion: 'test',
        environment: Environment.dev,
      ),
      preferences: preferences,
      stableDeviceId: StableDeviceIdService(preferences: preferences),
      queue: queue,
      sender: sender,
      logPathResolver: LogPathResolver(tempDirectory),
      coreService: coreService,
      activeProfileReader: () async => null,
      configOptionsSnapshotReader: () => null,
      locale: 'en',
    );

    try {
      await controller.init();
      await sender.started.future.timeout(const Duration(seconds: 2));

      controller.dispose();
      sender.release.complete();
      await sender.completed.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);

      final persisted = queue.dueReports(DateTime.now().toUtc().add(const Duration(days: 1)));
      expect(persisted, hasLength(1));
      expect(persisted.single.eventId, 'queued-before-init');
      expect(persisted.single.attempts, 0);
      expect(preferences.getString('diagnostics_last_vpn_not_running_report_at'), isNull);
    } finally {
      controller.dispose();
      if (!sender.release.isCompleted) sender.release.complete();
      container.dispose();
      LoggerController.instance.removePrinter('app');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tempDirectory.delete(recursive: true);
    }
  });
}

class _BlockingErrorReportSender with InfraLogger implements ErrorReportSender {
  final started = Completer<void>();
  final release = Completer<void>();
  final completed = Completer<void>();

  @override
  Future<void> send(Map<String, dynamic> report) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    if (!completed.isCompleted) completed.complete();
  }
}
