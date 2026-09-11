# Reproducible Builds (Windows, macOS, Linux, Android)

> **Статус: GUIDE / VERIFY BEFORE USE.** Инструкция сборки, не приёмка продукта. Перед выполнением сверить команды с текущими scripts и закреплённым SDK; структурирование не является свежей проверкой всех команд. Команды запускать из корня репозитория. [Навигация](../README.md).

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

Public local entrypoints are documented in [`scripts/README.md`](../../scripts/README.md).
Use them instead of assembling a new direct Flutter/Fastforge command:

```powershell
.\scripts\build.ps1 -Action android-apk
.\scripts\build.ps1 -Action windows-folder
.\scripts\build.ps1 -Action windows-portable
.\scripts\build.ps1 -Action windows-exe
.\scripts\build.ps1 -Action windows-runtime
```

On macOS:

```bash
./scripts/build.sh macos-artifacts
./scripts/build.sh ios-ipa
```

Every installable or distributable result is published below `out/installers`.
Flutter, Gradle, CMake, Fastforge and Xcode paths under `build`, `dist` or temporary
workspaces are intermediate outputs, not handoff artifacts.

`windows-runtime` is the dedicated headless lifecycle harness, not a release
client. It requires a clean committed tree, the exact Flutter version declared
in `pubspec.yaml`, `tool/windows_recovery_runtime.dart`, portable mode and the
test-only compile guard. The resulting ZIP and provenance manifest are published
under `out/installers/win`. A manifest maps version/build number to source SHA,
build type/time and artifact/native hashes. The script refuses to overwrite a
previously recorded build number; increment `+N` in `pubspec.yaml` before the
next actual compilation.

The `ZEON-W10-LAB` controller is `scripts/windows_runtime_lab.ps1`. It restores
the clean QEMU/TCG snapshot, waits for WinRM, stages hash-verified inputs, starts
an elevated hidden Scheduled Task and retrieves `result.json`, `events.jsonl`,
logs and network evidence. The task survives loss of the controller session;
`-CollectOnly -RunId <id>` resumes evidence collection. The controller performs
no UI automation and restores the stopped clean snapshot after ordinary runs.

## 4) Team rules to avoid drift

- Always commit `pubspec.lock`.
- Never edit `android/local.properties` and similar local machine files in git.
- Do not remove or partially update `hiddify-core` files; treat it as versioned source in this repository.
- Add or repair application build flows in `scripts/build.ps1`, `scripts/build.sh`
  and their shared implementation. Do not document an ad-hoc bypass when a script fails.
