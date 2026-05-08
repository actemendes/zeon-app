# Build Scripts

Recommended release scripts:

1. `build_windows_installer_exe.ps1`
Builds Windows installer EXE (`ZEON-Windows-Setup-x64.exe`) using `lib/main_prod.dart`.

2. `build_android_installation_apks.ps1`
Builds Android installation APK files (split-per-ABI and/or universal) using `lib/main_prod.dart`.

3. `build_and_install_android_device.ps1`
Builds and installs app on connected Android device using `lib/main_prod.dart`.

4. `build_windows_release_folder.ps1`
Builds Windows app into `build/windows/x64/runner/Release` using `lib/main_prod.dart`.

Compatibility scripts (also now support `-BuildTarget` and default to `lib/main_prod.dart`):

- `build_and_install_windows.ps1`
- `build_and_install_android.ps1`

