import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const _tokenQuery = 0x0008;
const _tokenElevation = 20;

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
