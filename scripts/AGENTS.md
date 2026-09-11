# ZEON build scripts

`build.ps1` is the canonical entrypoint for Windows and Android application builds.
`build.sh` is the canonical entrypoint for Apple application builds. Keep existing
specialized scripts as implementation details or compatibility wrappers; new build
flows must be added to these entrypoints instead of creating an unrelated script.

Every installable or distributable artifact must be published below the repository
`out/installers` directory. Platform tool output in `build`, `dist`, Xcode DerivedData,
Gradle, or a temporary workspace is intermediate only and must never be documented
or handed off as the final artifact.

When a build command fails, reproduce and fix the canonical script or its shared
implementation, then update its focused test and `README.md`. Do not work around a
broken script with an undocumented direct `flutter build`, Fastforge, Gradle, Xcode,
or packaging command.

Do not run runtime acceptance automatically. Follow `../docs/testing/README.md` and
hand a committed candidate plus paths and hashes from `out/installers` to the separate
test task or executor.
