import 'dart:typed_data';

import 'package:win32/win32.dart';
import 'package:win32_registry/win32_registry.dart';

/// Per-user startup registration for unpackaged Windows applications.
/// A new Windows profile need not contain either startup registry key.
class WindowsAutoStart {
  WindowsAutoStart({
    required this.appName,
    required this.executablePath,
    this.runKeyPath = r'Software\Microsoft\Windows\CurrentVersion\Run',
    this.approvedKeyPath = r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
  });

  final String appName;
  final String executablePath;
  final String runKeyPath;
  final String approvedKeyPath;

  String get _command => '"$executablePath"';
  bool _owns(String? value) => value == _command || value == executablePath;

  RegistryKey? _open(String path, {AccessRights access = AccessRights.readOnly}) {
    try {
      return Registry.openPath(RegistryHive.currentUser, path: path, desiredAccessRights: access);
    } on WindowsException catch (error) {
      if (_missing(error)) return null;
      rethrow;
    }
  }

  static bool _missing(WindowsException error) =>
      error.hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) || error.hr == HRESULT_FROM_WIN32(ERROR_PATH_NOT_FOUND);

  bool isEnabled() {
    final run = _open(runKeyPath);
    if (run == null) return false;
    try {
      if (!_owns(run.getStringValue(appName))) return false;
    } finally {
      run.close();
    }
    final approved = _open(approvedKeyPath);
    if (approved == null) return true;
    try {
      final value = approved.getBinaryValue(appName);
      return value == null || value.isEmpty || value.first.isEven;
    } finally {
      approved.close();
    }
  }

  void _write(String path, RegistryValue value) {
    final root = Registry.currentUser;
    try {
      final key = root.createKey(path);
      try {
        key.createValue(value);
      } finally {
        key.close();
      }
    } finally {
      root.close();
    }
  }

  void enable() {
    final approval = Uint8List(12)..[0] = 2;
    _write(approvedKeyPath, RegistryValue.binary(appName, approval));
    _write(runKeyPath, RegistryValue.string(appName, _command));
  }

  void _remove(String path) {
    final key = _open(path, access: AccessRights.writeOnly);
    if (key == null) return;
    try {
      key.deleteValue(appName);
    } on WindowsException catch (error) {
      if (!_missing(error)) rethrow;
    } finally {
      key.close();
    }
  }

  void disable() {
    final run = _open(runKeyPath);
    try {
      final value = run?.getStringValue(appName);
      if (value != null && !_owns(value)) return;
    } finally {
      run?.close();
    }
    _remove(runKeyPath);
    _remove(approvedKeyPath);
  }
}
