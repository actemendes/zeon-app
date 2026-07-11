import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:loggy/loggy.dart' as loggy;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:zeon/core/logger/logger.dart';
import 'package:zeon/core/logger/logger_controller.dart';
import 'package:zeon/core/model/app_info_entity.dart';
import 'package:zeon/features/connection/model/connection_failure.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/diagnostics/data/diagnostics_log_printer.dart';
import 'package:zeon/features/diagnostics/data/error_report_queue.dart';
import 'package:zeon/features/diagnostics/data/error_report_redactor.dart';
import 'package:zeon/features/diagnostics/data/error_report_sender.dart';
import 'package:zeon/features/log/data/log_path_resolver.dart';
import 'package:zeon/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:zeon/features/mobile/data/stable_device_id_service.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/singbox/model/singbox_config_option.dart';
import 'package:zeon/utils/platform_utils.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart' as hcore;
import 'package:zeon/zeoncore/zeon_core_service.dart';

typedef ActiveProfileReader = Future<ProfileEntity?> Function();
typedef ConfigOptionsSnapshotReader = SingboxConfigOption? Function();

class ErrorReportController {
  ErrorReportController({
    required AppInfoEntity appInfo,
    required SharedPreferences preferences,
    required StableDeviceIdService stableDeviceId,
    required ErrorReportQueue queue,
    required ErrorReportSender sender,
    required LogPathResolver logPathResolver,
    required ZeonCoreService coreService,
    required ActiveProfileReader activeProfileReader,
    required ConfigOptionsSnapshotReader configOptionsSnapshotReader,
    required String locale,
  }) : _appInfo = appInfo,
       _preferences = preferences,
       _stableDeviceId = stableDeviceId,
       _queue = queue,
       _sender = sender,
       _logPathResolver = logPathResolver,
       _coreService = coreService,
       _activeProfileReader = activeProfileReader,
       _configOptionsSnapshotReader = configOptionsSnapshotReader,
       _locale = locale;

  static const _enabled = bool.fromEnvironment('client_error_reporting_enabled', defaultValue: true);
  static const _platformChannel = MethodChannel('com.zeon.app/platform');
  static const _startupStoppedReportKey = 'diagnostics_last_vpn_not_running_report_at';

  final AppInfoEntity _appInfo;
  final SharedPreferences _preferences;
  final StableDeviceIdService _stableDeviceId;
  final ErrorReportQueue _queue;
  final ErrorReportSender _sender;
  final LogPathResolver _logPathResolver;
  final ZeonCoreService _coreService;
  final ActiveProfileReader _activeProfileReader;
  final ConfigOptionsSnapshotReader _configOptionsSnapshotReader;
  final String _locale;
  final ErrorReportRedactor _redactor = const ErrorReportRedactor();

  DiagnosticsLogPrinter? _logPrinter;
  Timer? _flushTimer;
  bool _initialized = false;
  bool _flushing = false;

  Future<void> init() async {
    if (!_enabled || kIsWeb || _initialized) return;
    _initialized = true;
    Logger.setSilentErrorReporter((trigger, error, stackTrace, message) {
      return captureError(trigger: trigger, error: error, stackTrace: stackTrace, message: message);
    });
    _logPrinter = DiagnosticsLogPrinter(onErrorRecord: captureLogRecord);
    LoggerController.instance.addPrinter('diagnostics', _logPrinter!);
    _flushTimer = Timer.periodic(const Duration(minutes: 1), (_) => unawaited(flush()));
    await flush();
    await _captureVpnNotRunningOnStartupIfNeeded();
  }

  void dispose() {
    Logger.clearSilentErrorReporter();
    _flushTimer?.cancel();
    if (_logPrinter != null) {
      LoggerController.instance.removePrinter('diagnostics');
    }
  }

  Future<void> captureError({
    required String trigger,
    required Object error,
    StackTrace? stackTrace,
    String? message,
    Map<String, dynamic>? context,
    String severity = 'error',
  }) async {
    if (!_enabled || kIsWeb) return;
    final report = await _buildReport(
      trigger: trigger,
      severity: severity,
      error: error,
      stackTrace: stackTrace,
      message: message,
      context: context,
    );
    await _queue.enqueue(report);
    await flush();
  }

  Future<void> captureLogRecord(loggy.LogRecord record) {
    return captureError(
      trigger: 'log_error',
      error: record.error ?? Exception(record.message),
      stackTrace: record.stackTrace,
      message: record.message,
      context: {'logger_name': record.loggerName, 'level': record.level.name, 'sequence_number': record.sequenceNumber},
      severity: record.level == loggy.LogLevel.error ? 'error' : 'fatal',
    );
  }

  Future<void> captureConnectionFailure(ConnectionFailure failure, StackTrace stackTrace) {
    return captureError(
      trigger: 'connection_failure',
      error: failure,
      stackTrace: stackTrace,
      message: failure.toString(),
      context: {'failure_type': failure.runtimeType.toString()},
    );
  }

  Future<void> captureUnexpectedVpnDisconnect({
    required ConnectionStatus? previousStatus,
    required Disconnected disconnected,
    required String? lastUserAction,
    required DateTime? lastUserActionAt,
    required bool startedByUser,
  }) async {
    if (!_enabled || kIsWeb) return;
    final failure = disconnected.connectionFailure;
    final context = <String, dynamic>{
      'status_before': previousStatus?.format(),
      'status_after': disconnected.format(),
      'last_user_action': lastUserAction,
      'last_user_action_at': lastUserActionAt?.toUtc().toIso8601String(),
      'started_by_user': startedByUser,
      if (failure != null) 'connection_failure': failure.toString(),
    };
    await captureError(
      trigger: 'vpn_unexpected_disconnect',
      error: failure ?? StateError('VPN disconnected without an expected stop command'),
      stackTrace: StackTrace.current,
      message: failure?.toString() ?? 'VPN disconnected without an expected stop command',
      context: context,
    );
  }

  Future<void> flush() async {
    if (!_enabled || kIsWeb || _flushing) return;
    _flushing = true;
    try {
      final due = _queue.dueReports(DateTime.now().toUtc());
      for (final entry in due) {
        try {
          await _sender.send(entry.report);
          await _queue.remove(entry.eventId);
        } catch (_) {
          await _queue.markFailed(entry.eventId);
        }
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> _captureVpnNotRunningOnStartupIfNeeded() async {
    if (_preferences.getBool('started_by_user') != true || _coreService.currentState is! CoreStopped) {
      return;
    }

    final now = DateTime.now().toUtc();
    final lastReported = DateTime.tryParse((_preferences.getString(_startupStoppedReportKey) ?? '').trim())?.toUtc();
    if (lastReported != null && lastReported.isAfter(now.subtract(const Duration(hours: 6)))) {
      return;
    }

    await _preferences.setString(_startupStoppedReportKey, now.toIso8601String());
    await captureError(
      trigger: 'vpn_not_running_on_startup',
      error: StateError('VPN was expected to be running but core is stopped on app startup'),
      stackTrace: StackTrace.current,
      message: 'VPN was expected to be running but core is stopped on app startup',
      context: {'started_by_user': true, 'core_status_at_startup': _formatCoreStatus(_coreService.currentState)},
    );
  }

  Future<Map<String, dynamic>> _buildReport({
    required String trigger,
    required String severity,
    required Object error,
    StackTrace? stackTrace,
    String? message,
    Map<String, dynamic>? context,
  }) async {
    final occurredAt = DateTime.now().toUtc();
    final eventId = const Uuid().v4();
    final activeProfile = await _tryReadActiveProfile();
    final runtimeNetwork = await _readRuntimeNetworkInfo();
    final userId = _readUserId();
    final login = _resolveLogin(activeProfile);
    final configOptions = _safeConfigSnapshot();
    final safeMessage = _redactor.redactText(message ?? error.toString());
    final safeStack = stackTrace == null ? null : _redactor.redactText(stackTrace.toString(), maxLength: 20000);
    final fingerprint = _fingerprint([
      trigger,
      error.runtimeType.toString(),
      _normalizeFingerprintText(safeMessage),
      _normalizeFingerprintText(_firstStackLine(safeStack)),
    ]);

    final report = <String, dynamic>{
      'schema_version': 1,
      'event_id': eventId,
      'occurred_at': occurredAt.toIso8601String(),
      'trigger': trigger,
      'severity': severity,
      'fingerprint': fingerprint,
      'app': {
        'name': _appInfo.name,
        'version': _appInfo.version,
        'build_number': _appInfo.buildNumber,
        'environment': _appInfo.environment.name,
        'release': _appInfo.release.name,
      },
      'device': {
        'device_id': await _stableDeviceId.getOrCreate(),
        'platform': _platformName(),
        'os_version': PlatformUtils.operatingSystemVersion,
        'locale': _locale,
        if (userId != null) 'user_id': userId,
        if (login != null && login.isNotEmpty) 'login': _redactor.redactText(login, maxLength: 300),
      },
      'vpn': {
        'core_status': _formatCoreStatus(_coreService.currentState),
        'started_by_user': _preferences.getBool('started_by_user') ?? false,
        'service_mode': _preferences.getString('service-mode'),
        'network_transport': runtimeNetwork.transport,
        'network_mtu': runtimeNetwork.mtu,
        if (activeProfile != null) 'active_profile': _profileSummary(activeProfile),
        if (configOptions != null) 'config_options': configOptions,
      },
      'error': {
        'type': error.runtimeType.toString(),
        'message': safeMessage,
        if (safeStack != null) 'stack_trace': safeStack,
      },
      'logs': await _logs(),
      if (context != null && context.isNotEmpty) 'context': _redactor.redactJson(context),
    };
    return _preserveAppMetadata(_redactor.redactMap(report));
  }

  Map<String, dynamic> _preserveAppMetadata(Map<String, dynamic> report) {
    final app = Map<String, dynamic>.from((report['app'] as Map?) ?? const <String, dynamic>{});
    app['name'] = _appInfo.name;
    app['version'] = _appInfo.version;
    app['build_number'] = _appInfo.buildNumber;
    app['environment'] = _appInfo.environment.name;
    app['release'] = _appInfo.release.name;
    report['app'] = app;
    return report;
  }

  Future<ProfileEntity?> _tryReadActiveProfile() async {
    try {
      return await _activeProfileReader().timeout(const Duration(milliseconds: 800));
    } catch (_) {
      return null;
    }
  }

  int? _readUserId() {
    final canonical = int.tryParse((_preferences.getString(MobileConnLinkImportService.prefUserId) ?? '').trim());
    if (canonical != null && canonical > 0) return canonical;
    final legacy = int.tryParse((_preferences.getString('mobile_payment_user_id') ?? '').trim());
    return legacy != null && legacy > 0 ? legacy : null;
  }

  String? _resolveLogin(ProfileEntity? profile) {
    final name = profile?.name.trim();
    if (name == null || name.isEmpty) return null;
    return name;
  }

  Map<String, dynamic> _profileSummary(ProfileEntity profile) {
    return switch (profile) {
      RemoteProfileEntity(:final id, :final name, :final url, :final subInfo) => {
        'id': id,
        'type': 'remote',
        'name': name,
        'url_host': Uri.tryParse(url)?.host,
        if (subInfo != null) 'expires_at': subInfo.expire.toUtc().toIso8601String(),
      },
      LocalProfileEntity(:final id, :final name) => {'id': id, 'type': 'local', 'name': name},
    };
  }

  Map<String, dynamic>? _safeConfigSnapshot() {
    try {
      final options = _configOptionsSnapshotReader();
      if (options == null) return null;
      return {
        'network_profile': options.networkProfile,
        'tun_implementation': options.tunImplementation.name,
        'strict_route': options.strictRoute,
        'mtu': options.mtu,
      };
    } catch (_) {
      return null;
    }
  }

  Future<({String transport, int mtu})> _readRuntimeNetworkInfo() async {
    if (kIsWeb) return (transport: 'web', mtu: 0);
    try {
      final info = await _platformChannel.invokeMapMethod<String, dynamic>('get_network_runtime_info');
      final transport = (info?['network-transport-type'] ?? 'unknown').toString();
      final mtuRaw = info?['network-interface-mtu'];
      final mtu = switch (mtuRaw) {
        final int value => value,
        final num value => value.toInt(),
        final String value => int.tryParse(value) ?? 0,
        _ => 0,
      };
      return (transport: transport, mtu: mtu);
    } catch (_) {
      return (transport: 'unknown', mtu: 0);
    }
  }

  String _formatCoreStatus(CoreStatus status) {
    return switch (status) {
      CoreStarted() => 'Started',
      CoreStarting() => 'Starting',
      CoreStopping() => 'Stopping',
      CoreStopped(:final alert, :final message) =>
        'Stopped${alert == null ? "" : " alert=${alert.name}"}${message == null ? "" : " message=$message"}',
    };
  }

  Future<Map<String, dynamic>> _logs() async {
    return {
      'app_tail': _logPrinter?.snapshot() ?? const <String>[],
      'core_tail': _coreService.logBuffer.takeLast(120).map(_formatCoreLog).toList(growable: false),
      'app_file_tail': await _readFileTail(_logPathResolver.appFile(), maxLines: 80),
      'core_file_tail': await _readFileTail(_logPathResolver.coreFile(), maxLines: 80),
      'stderr_tail': await _readFileTail(File(p.join(_logPathResolver.directory.path, 'stderr.log')), maxLines: 80),
      'truncated': true,
    };
  }

  String _formatCoreLog(hcore.LogMessage message) {
    final time = message.hasTime() ? message.time.toDateTime().toUtc().toIso8601String() : '';
    return _redactor.redactText('$time [${message.level.name}] ${message.message}', maxLength: 2000);
  }

  Future<List<String>> _readFileTail(File file, {required int maxLines, int maxBytes = 60000}) async {
    try {
      if (!await file.exists()) return const [];
      final length = await file.length();
      final start = length > maxBytes ? length - maxBytes : 0;
      final raf = await file.open();
      try {
        await raf.setPosition(start);
        final bytes = await raf.read(length - start);
        final content = utf8.decode(bytes, allowMalformed: true);
        final lines = const LineSplitter().convert(_redactor.redactText(content, maxLength: maxBytes));
        final normalizedLines = start > 0 && lines.length > 1 ? lines.sublist(1) : lines;
        final tailStart = normalizedLines.length > maxLines ? normalizedLines.length - maxLines : 0;
        return normalizedLines.sublist(tailStart);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return const [];
    }
  }

  String _platformName() {
    if (PlatformUtils.isAndroid) return 'android';
    if (PlatformUtils.isIOS) return 'ios';
    if (PlatformUtils.isMacOS) return 'macos';
    if (PlatformUtils.isWindows) return 'windows';
    if (PlatformUtils.isLinux) return 'linux';
    return 'unknown';
  }

  String? _firstStackLine(String? stackTrace) {
    if (stackTrace == null || stackTrace.isEmpty) return null;
    return stackTrace.split('\n').firstOrNull;
  }

  String? _normalizeFingerprintText(String? value) {
    if (value == null || value.isEmpty) return value;
    var normalized = value;
    normalized = normalized.replaceAll(
      RegExp(r'address = <redacted>, port = \d+'),
      'address = <redacted>, port = <port>',
    );
    normalized = normalized.replaceAll(RegExp(r'address = [^,\)]+, port = \d+'), 'address = <address>, port = <port>');
    normalized = normalized.replaceAll(RegExp(r'port = \d+'), 'port = <port>');
    return normalized;
  }

  String _fingerprint(List<Object?> parts) {
    final input = parts.whereType<Object>().join('|');
    var hash = 0xcbf29ce484222325;
    for (final unit in utf8.encode(input)) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0x1fffffffffffff;
    }
    return hash.toRadixString(16);
  }
}

extension _TakeLast<T> on List<T> {
  Iterable<T> takeLast(int count) {
    if (length <= count) return this;
    return sublist(length - count);
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
