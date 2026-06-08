import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const _tokenQuery = 0x0008;
const _tokenElevation = 20;
const _hkeyLocalMachine = 0x80000002;
const _rrfRtRegDword = 0x00000010;

bool? isWindowsUacEnabled() {
  if (!Platform.isWindows) return null;

  final advapi32 = DynamicLibrary.open('advapi32.dll');
  final regGetValue = advapi32
      .lookupFunction<
        Int32 Function(
          IntPtr hkey,
          Pointer<Utf16> subKey,
          Pointer<Utf16> value,
          Uint32 flags,
          Pointer<Uint32> type,
          Pointer<Void> data,
          Pointer<Uint32> dataSize,
        ),
        int Function(
          int hkey,
          Pointer<Utf16> subKey,
          Pointer<Utf16> value,
          int flags,
          Pointer<Uint32> type,
          Pointer<Void> data,
          Pointer<Uint32> dataSize,
        )
      >('RegGetValueW');

  final subKey = 'SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System'.toNativeUtf16();
  final value = 'EnableLUA'.toNativeUtf16();
  final type = calloc<Uint32>();
  final data = calloc<Uint32>();
  final dataSize = calloc<Uint32>()..value = sizeOf<Uint32>();
  try {
    final result = regGetValue(_hkeyLocalMachine, subKey, value, _rrfRtRegDword, type, data.cast<Void>(), dataSize);
    if (result != 0) return null;
    return data.value != 0;
  } finally {
    calloc.free(subKey);
    calloc.free(value);
    calloc.free(type);
    calloc.free(data);
    calloc.free(dataSize);
  }
}

bool? isWindowsProcessElevated() {
  if (!Platform.isWindows) return null;

  final advapi32 = DynamicLibrary.open('advapi32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');

  final openProcessToken = advapi32
      .lookupFunction<
        Int32 Function(IntPtr processHandle, Uint32 desiredAccess, Pointer<IntPtr> tokenHandle),
        int Function(int processHandle, int desiredAccess, Pointer<IntPtr> tokenHandle)
      >('OpenProcessToken');
  final getTokenInformation = advapi32
      .lookupFunction<
        Int32 Function(
          IntPtr tokenHandle,
          Uint32 tokenInformationClass,
          Pointer<Void> tokenInformation,
          Uint32 tokenInformationLength,
          Pointer<Uint32> returnLength,
        ),
        int Function(
          int tokenHandle,
          int tokenInformationClass,
          Pointer<Void> tokenInformation,
          int tokenInformationLength,
          Pointer<Uint32> returnLength,
        )
      >('GetTokenInformation');
  final getCurrentProcess = kernel32.lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
  final closeHandle = kernel32.lookupFunction<Int32 Function(IntPtr handle), int Function(int handle)>('CloseHandle');

  final tokenHandle = calloc<IntPtr>();
  final tokenElevation = calloc<Uint32>();
  final returnLength = calloc<Uint32>();
  try {
    if (openProcessToken(getCurrentProcess(), _tokenQuery, tokenHandle) == 0) {
      return null;
    }

    final success = getTokenInformation(
      tokenHandle.value,
      _tokenElevation,
      tokenElevation.cast<Void>(),
      sizeOf<Uint32>(),
      returnLength,
    );
    if (success == 0) return null;

    return tokenElevation.value != 0;
  } finally {
    if (tokenHandle.value != 0) {
      closeHandle(tokenHandle.value);
    }
    calloc.free(tokenHandle);
    calloc.free(tokenElevation);
    calloc.free(returnLength);
  }
}
