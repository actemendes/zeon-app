# Reproducible Builds (Windows, macOS, Linux, Android)

## 1) Clone correctly

```bash
git clone <repo-url>
cd zeon-app
```

## 2) Bootstrap environment

Windows (PowerShell):

```powershell
.\scripts\bootstrap.ps1
```

macOS/Linux:

```bash
bash ./scripts/bootstrap.sh
```

What bootstrap does:
- verifies vendored `hiddify-core` exists in repository;
- validates Flutter version against `pubspec.yaml`;
- resolves dependencies with lockfile (`flutter pub get --enforce-lockfile`).

## 3) Build targets

- Android: `make android-prepare && make android-apk-release`
- Windows: `make windows-prepare && make windows-release`
- macOS: `make macos-prepare && make macos-release`

## 4) Team rules to avoid drift

- Always commit `pubspec.lock`.
- Never edit `android/local.properties` and similar local machine files in git.
- Do not remove or partially update `hiddify-core` files; treat it as versioned source in this repository.
