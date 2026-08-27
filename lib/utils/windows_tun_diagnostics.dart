import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

Map<String, Object?> windowsTunFailureDiagnostic({required String stage, required bool? elevated, Object? error}) {
  final text = error?.toString() ?? '';
  final fwpmMatch = RegExp(r'Fwpm([A-Za-z0-9_]+)').firstMatch(text);
  final hresultMatch = RegExp(r'0x[0-9a-fA-F]{8}').firstMatch(text);
  final hresult = hresultMatch == null ? null : int.tryParse(hresultMatch.group(0)!.substring(2), radix: 16);
  final isFilterAdd = text.toLowerCase().contains('fwpmfilteradd');

  return <String, Object?>{
    'event': 'windows_tun_failure',
    'stage': isFilterAdd ? 'wfp_filter_add' : stage,
    'native_operation': fwpmMatch?.group(0),
    'hresult': hresult == null ? null : '0x${hresult.toRadixString(16).padLeft(8, '0')}',
    'win32_code': hresult == null || (hresult & 0xffff0000) != 0x80070000 ? null : hresult & 0xffff,
    'elevated': elevated,
    'bfe_state': windowsBfeState(),
    // Ownership is intentionally explicit: Dart does not delete or enumerate
    // WFP filters. The bundled native core remains the sole owner.
    'filter_owner_scope': 'native_core_only',
  };
}

String windowsBfeState() {
  if (!Platform.isWindows) return 'not_applicable';
  final api = _ServiceControlApi();
  final manager = api.openScManager(nullptr, nullptr, _scManagerConnect);
  if (manager == 0) return 'unavailable';
  Pointer<Utf16>? serviceName;
  var service = 0;
  try {
    serviceName = 'BFE'.toNativeUtf16();
    service = api.openService(manager, serviceName, _serviceQueryStatus);
    if (service == 0) return 'unavailable';
    final status = calloc<Uint32>(9);
    final bytesNeeded = calloc<Uint32>();
    try {
      final ok = api.queryServiceStatusEx(
        service,
        _scStatusProcessInfo,
        status.cast<Uint8>(),
        sizeOf<Uint32>() * 9,
        bytesNeeded,
      );
      if (ok == 0) return 'unavailable';
      return bfeStateNameForTesting(status[1]);
    } finally {
      calloc.free(status);
      calloc.free(bytesNeeded);
    }
  } catch (_) {
    return 'unavailable';
  } finally {
    if (service != 0) api.closeServiceHandle(service);
    api.closeServiceHandle(manager);
    if (serviceName != null) calloc.free(serviceName);
  }
}

@visibleForTesting
String bfeStateNameForTesting(int state) => switch (state) {
  1 => 'stopped',
  2 => 'start_pending',
  3 => 'stop_pending',
  4 => 'running',
  5 => 'continue_pending',
  6 => 'pause_pending',
  7 => 'paused',
  _ => 'unknown',
};

const _scManagerConnect = 0x0001;
const _serviceQueryStatus = 0x0004;
const _scStatusProcessInfo = 0;

class _ServiceControlApi {
  _ServiceControlApi() {
    final library = DynamicLibrary.open('advapi32.dll');
    openScManager = library.lookupFunction<_OpenScManagerNative, _OpenScManagerDart>('OpenSCManagerW');
    openService = library.lookupFunction<_OpenServiceNative, _OpenServiceDart>('OpenServiceW');
    queryServiceStatusEx = library.lookupFunction<_QueryServiceStatusExNative, _QueryServiceStatusExDart>(
      'QueryServiceStatusEx',
    );
    closeServiceHandle = library.lookupFunction<_CloseServiceHandleNative, _CloseServiceHandleDart>(
      'CloseServiceHandle',
    );
  }

  late final _OpenScManagerDart openScManager;
  late final _OpenServiceDart openService;
  late final _QueryServiceStatusExDart queryServiceStatusEx;
  late final _CloseServiceHandleDart closeServiceHandle;
}

typedef _OpenScManagerNative = IntPtr Function(Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _OpenScManagerDart = int Function(Pointer<Utf16>, Pointer<Utf16>, int);
typedef _OpenServiceNative = IntPtr Function(IntPtr, Pointer<Utf16>, Uint32);
typedef _OpenServiceDart = int Function(int, Pointer<Utf16>, int);
typedef _QueryServiceStatusExNative = Int32 Function(IntPtr, Int32, Pointer<Uint8>, Uint32, Pointer<Uint32>);
typedef _QueryServiceStatusExDart = int Function(int, int, Pointer<Uint8>, int, Pointer<Uint32>);
typedef _CloseServiceHandleNative = Int32 Function(IntPtr);
typedef _CloseServiceHandleDart = int Function(int);
