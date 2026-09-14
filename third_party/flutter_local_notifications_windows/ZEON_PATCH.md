# ZEON local patch

Upstream basis: `flutter_local_notifications_windows` 3.1.0.

The Windows toast implementation uses a C-compatible FFI surface implemented in
C++. Upstream lets WinRT/C++ exceptions escape several exported functions. An
exception crossing that ABI boundary terminates the Flutter process before Dart can
select the application's in-app notification fallback.

This copy contains every native exception at the FFI boundary, reports failure using
the existing return values, and revokes the COM activation callback when initialization
fails or the plugin is disposed. The Dart wrapper also disposes a native instance that
failed initialization. Remove the path dependency only after upstream has equivalent
fail-safe behavior and the session-0/platform-unavailable regression has been rerun.
