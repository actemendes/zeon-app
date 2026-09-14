import 'dart:async';
import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:zeon/core/app_info/app_info_provider.dart';
import 'package:zeon/features/auto_start/data/windows_auto_start.dart';
import 'package:zeon/utils/utils.dart';

part 'auto_start_notifier.g.dart';

@Riverpod(keepAlive: true)
class AutoStartNotifier extends _$AutoStartNotifier with InfraLogger {
  Timer? _timer;
  WindowsAutoStart? _windowsAutoStart;

  @override
  Future<bool> build() async {
    if (!PlatformUtils.isDesktop) return false;
    final appInfo = ref.watch(appInfoProvider).requireValue;
    launchAtStartup.setup(appName: appInfo.name, appPath: Platform.resolvedExecutable, packageName: "ZEON.ZEON");
    final isMsix =
        Platform.resolvedExecutable.contains('WindowsApps') && Platform.resolvedExecutable.contains('ZEON.ZEON');
    if (Platform.isWindows && !isMsix) {
      _windowsAutoStart = WindowsAutoStart(appName: appInfo.name, executablePath: Platform.resolvedExecutable);
    }
    final isEnabled = await _isEnabled();
    loggy.info("auto start is [${isEnabled ? "Enabled" : "Disabled"}]");
    _startTimer();
    ref.onDispose(() => _timer?.cancel());
    return isEnabled;
  }

  Future<bool> _isEnabled() async => _windowsAutoStart?.isEnabled() ?? await launchAtStartup.isEnabled();

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 15), (timer) => updateStatus());
  }

  Future<bool> updateStatus() async {
    loggy.debug("update auto start status");
    final isEnabled = await _isEnabled();
    state = AsyncValue.data(isEnabled);
    return isEnabled;
  }

  Future<void> enable() async {
    loggy.debug("enabling auto start");
    if (_windowsAutoStart case final windows?) {
      windows.enable();
    } else {
      await launchAtStartup.enable();
    }
    state = const AsyncValue.data(true);
  }

  Future<void> disable() async {
    loggy.debug("disabling auto start");
    if (_windowsAutoStart case final windows?) {
      windows.disable();
    } else {
      await launchAtStartup.disable();
    }
    state = const AsyncValue.data(false);
  }
}
