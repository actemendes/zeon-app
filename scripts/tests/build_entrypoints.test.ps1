$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$scriptDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$repoRoot = Split-Path -Parent $scriptDir
$commonPath = Join-Path $scriptDir "build\common.ps1"
. $commonPath

$powershellFiles = @(
    "build.ps1",
    "build\common.ps1",
    "build_windows_portable.ps1",
    "build_windows_runtime.ps1",
    "build_android_runtime.ps1",
    "build_google_play.ps1",
    "windows_runtime_lab.ps1",
    "build_windows_release_folder.ps1",
    "build_windows_installer_exe.ps1",
    "build_windows_installer_msix.ps1",
    "package_windows_installers.ps1",
    "build_android_installation_apks.ps1",
    "build_and_install_android.ps1"
)

foreach ($relativePath in $powershellFiles) {
    $path = Join-Path $scriptDir $relativePath
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-True -Condition ($parseErrors.Count -eq 0) -Message "PowerShell parser errors in $relativePath"
}

$help = (& (Join-Path $scriptDir "build.ps1") -ListActions 6>&1 | Out-String)
foreach ($action in @(
    "windows-folder",
    "windows-portable",
    "windows-exe",
    "windows-exe-unsigned",
    "windows-msix",
    "windows-runtime",
    "android-apk",
    "android-apks",
    "android-google-play",
    "android-runtime",
    "android-debug-install"
)) {
    Assert-True -Condition $help.Contains($action) -Message "Build action is missing from help: $action"
}

$testRoot = Join-Path "Z:\Zeon-Envelope\Temp" ("zeon-build-script-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $sourceFile = Join-Path $testRoot "source.apk"
    Set-Content -LiteralPath $sourceFile -Value "fixture" -NoNewline
    $publishedPath = Publish-ZeonFile `
        -RepoRoot $testRoot `
        -Platform "android" `
        -SourcePath $sourceFile `
        -DestinationName "ZEON-test.apk"
    $expectedRoot = [System.IO.Path]::GetFullPath((Join-Path $testRoot "out\installers"))
    Assert-True -Condition $publishedPath.StartsWith($expectedRoot, [System.StringComparison]::OrdinalIgnoreCase) -Message "Artifact escaped out/installers"

    $outsideWasRejected = $false
    try {
        Assert-ZeonInstallerPath -RepoRoot $testRoot -Path (Join-Path $testRoot "outside.apk") | Out-Null
    }
    catch {
        $outsideWasRejected = $true
    }
    Assert-True -Condition $outsideWasRejected -Message "Path guard accepted an artifact outside out/installers"

    # Exercise the real dispatcher and Play builder with local command doubles.
    # Fixture artifacts are text files; no Flutter/Gradle process or signing runs.
    $fixtureRoot = Join-Path $testRoot "google-play"
    foreach ($directory in @("scripts\build", "lib", "android\app\libs")) {
        New-Item -ItemType Directory -Path (Join-Path $fixtureRoot $directory) -Force | Out-Null
    }
    foreach ($scriptName in @("build.ps1", "build_google_play.ps1")) {
        Copy-Item -LiteralPath (Join-Path $scriptDir $scriptName) -Destination (Join-Path $fixtureRoot "scripts\$scriptName")
    }
    $fixtureCommon = Join-Path $fixtureRoot "scripts\build\common.ps1"
    Copy-Item -LiteralPath $commonPath -Destination $fixtureCommon
    Add-Content -LiteralPath $fixtureCommon -Value 'function Use-ZeonPinnedFlutter { param($RepoRoot) return "fixture-sdk" }'
    Set-Content -LiteralPath (Join-Path $fixtureRoot "pubspec.yaml") -Value "version: 1.2.3+456"
    Set-Content -LiteralPath (Join-Path $fixtureRoot "lib\main_prod.dart") -Value "fixture"
    Set-Content -LiteralPath (Join-Path $fixtureRoot "android\app\libs\hiddify-core.aar") -Value "fixture"
    Set-Content -LiteralPath (Join-Path $fixtureRoot "android\fixture.jks") -Value "fixture"
    $fixtureProperties = Join-Path $fixtureRoot "android\key.properties"
    Set-Content -LiteralPath $fixtureProperties -Value @(
        "storeFile=../fixture.jks", "storePassword=fixture", "keyPassword=fixture", "keyAlias=fixture"
    )
    $global:zeonGooglePlayFixtureCalls = [System.Collections.Generic.List[object]]::new()
    function flutter {
        $global:zeonGooglePlayFixtureCalls.Add([string[]]$args)
        if ($args[0] -eq "build") {
            $relativeOutput = switch ($args[1]) {
                "appbundle" { "build\app\outputs\bundle\release\app-release.aab" }
                "apk" { "build\app\outputs\flutter-apk\app-release.apk" }
                default { throw "Unexpected fixture build command" }
            }
            $output = Join-Path (Get-Location).Path $relativeOutput
            New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
            Set-Content -LiteralPath $output -Value "fixture artifact"
        }
        $global:LASTEXITCODE = 0
    }
    function dart { $global:LASTEXITCODE = 0 }
    $fixtureEntrypoint = Join-Path $fixtureRoot "scripts\build.ps1"
    $fixtureInstallers = Join-Path $fixtureRoot "out\installers\android"
    & $fixtureEntrypoint -Action android-google-play -SkipCodeGeneration 6>$null
    $defaultBuilds = @($global:zeonGooglePlayFixtureCalls | Where-Object { $_[0] -eq "build" })
    Assert-True -Condition ($defaultBuilds.Count -eq 1 -and $defaultBuilds[0][1] -eq "appbundle") -Message "Default Play action must only build AAB"
    Assert-True -Condition ($defaultBuilds[0] -contains '--android-project-arg=zeonTvOnly=false') -Message "Default Play action must retain mobile compatibility"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $fixtureInstallers "ZEON-1.2.3+456-google-play.aab")) -Message "Play AAB was not published"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $fixtureInstallers "ZEON-1.2.3+456-google-play.apk"))) -Message "Default Play action unexpectedly published APK"

    $global:zeonGooglePlayFixtureCalls.Clear()
    & $fixtureEntrypoint -Action android-google-play -IncludeInstallApk -SkipCodeGeneration 6>$null
    $pairedBuilds = @($global:zeonGooglePlayFixtureCalls | Where-Object { $_[0] -eq "build" })
    Assert-True -Condition ($pairedBuilds.Count -eq 2 -and $pairedBuilds[0][1] -eq "appbundle" -and $pairedBuilds[1][1] -eq "apk") -Message "Opt-in Play action must build AAB then APK"
    Assert-True -Condition (($pairedBuilds[0][2..($pairedBuilds[0].Length - 1)] -join '|') -eq ($pairedBuilds[1][2..($pairedBuilds[1].Length - 1)] -join '|')) -Message "Play AAB and APK differ in target/defines/mode"
    Assert-True -Condition ($pairedBuilds[1] -contains "--release" -and $pairedBuilds[1] -contains "release=google-play") -Message "Install APK lost the Google Play release contract"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $fixtureInstallers "ZEON-1.2.3+456-google-play.apk")) -Message "Play APK was not published with a distinct name"

    $global:zeonGooglePlayFixtureCalls.Clear()
    & $fixtureEntrypoint -Action android-google-play -AndroidTvOnly -IncludeInstallApk -SkipCodeGeneration 6>$null
    $tvBuilds = @($global:zeonGooglePlayFixtureCalls | Where-Object { $_[0] -eq "build" })
    Assert-True -Condition ($tvBuilds.Count -eq 2) -Message "TV paired build must produce AAB and APK"
    foreach ($tvBuild in $tvBuilds) {
        Assert-True -Condition ($tvBuild -contains '--android-project-arg=zeonTvOnly=true') -Message "TV build must require Leanback"
        Assert-True -Condition ($tvBuild -contains 'release=google-play') -Message "TV build must retain store updater suppression"
    }
    Assert-True -Condition (($tvBuilds[0][2..($tvBuilds[0].Count - 1)] -join '|') -eq ($tvBuilds[1][2..($tvBuilds[1].Count - 1)] -join '|')) -Message "TV AAB and APK must use identical build options"
    foreach ($extension in @('aab', 'apk')) {
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $fixtureInstallers "ZEON-1.2.3+456-google-play-tv.$extension")) -Message "TV artifact needs a distinct name"
    }
    $global:zeonGooglePlayFixtureCalls.Clear()
    & $fixtureEntrypoint -Action android-google-play -SkipCodeGeneration 6>$null
    $afterTvBuilds = @($global:zeonGooglePlayFixtureCalls | Where-Object { $_[0] -eq "build" })
    Assert-True -Condition ($afterTvBuilds[0] -contains '--android-project-arg=zeonTvOnly=false') -Message "TV mode leaked into the next general build"

    $wrongTvActionRejected = $false
    try { & $fixtureEntrypoint -Action android-apk -AndroidTvOnly 6>$null }
    catch { $wrongTvActionRejected = $_.Exception.Message.Contains("only supported") }
    Assert-True -Condition $wrongTvActionRejected -Message "TV-only switch must reject non-Play actions"

    Remove-Item -LiteralPath $fixtureProperties
    $global:zeonGooglePlayFixtureCalls.Clear()
    $missingKeyRejected = $false
    try {
        & $fixtureEntrypoint -Action android-google-play -AndroidTvOnly -IncludeInstallApk -SkipCodeGeneration 6>$null
    }
    catch { $missingKeyRejected = $_.Exception.Message.Contains("configured upload keystore") }
    Assert-True -Condition $missingKeyRejected -Message "Play APK action must fail closed without signing configuration"
    Assert-True -Condition ($global:zeonGooglePlayFixtureCalls.Count -eq 0) -Message "Play action invoked Flutter before rejecting missing signing configuration"

    $wrongActionRejected = $false
    try {
        & $fixtureEntrypoint -Action android-apk -IncludeInstallApk 6>$null
    }
    catch { $wrongActionRejected = $_.Exception.Message.Contains("only supported") }
    Assert-True -Condition $wrongActionRejected -Message "Play-only install APK option was accepted for a general build"
}
finally {
    Remove-Variable -Name zeonGooglePlayFixtureCalls -Scope Global -ErrorAction SilentlyContinue
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $allowedPrefix = [System.IO.Path]::GetFullPath("Z:\Zeon-Envelope\Temp").TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTestRoot.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove unexpected test directory: $resolvedTestRoot"
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}

$appleBuild = Get-Content -LiteralPath (Join-Path $scriptDir "apple\build.sh") -Raw
Assert-True -Condition $appleBuild.Contains("out/installers") -Message "Apple build does not publish to out/installers"
Assert-True -Condition (-not $appleBuild.Contains("out/apple")) -Message "Apple build still publishes to out/apple"
Assert-True -Condition $appleBuild.Contains("build_and_install_ios_device") -Message "Apple entrypoint is missing iOS device installation"

$windowsBuilder = Get-Content -LiteralPath (Join-Path $scriptDir "build_and_install_windows.ps1") -Raw
Assert-True -Condition $windowsBuilder.Contains('$flutterExitCode') -Message "Windows Flutter version check must preserve the native exit code"
Assert-True -Condition $windowsBuilder.Contains('zeon_runtime_validation=true') -Message "Windows builder is missing the runtime compile-time guard"
Assert-True -Condition $windowsBuilder.Contains('zeon_source_sha=') -Message "Windows runtime build must embed source provenance"

$runtimeBuilder = Get-Content -LiteralPath (Join-Path $scriptDir "build_windows_runtime.ps1") -Raw
Assert-True -Condition $runtimeBuilder.Contains('build-registry.jsonl') -Message "Runtime builds must record their version/SHA mapping"
Assert-True -Condition $runtimeBuilder.Contains('Runtime artifacts must be built from a clean committed working tree') -Message "Runtime builds must reject dirty source"

$androidRuntimeBuilder = Get-Content -LiteralPath (Join-Path $scriptDir "build_android_runtime.ps1") -Raw
Assert-True -Condition $androidRuntimeBuilder.Contains(':app:assembleValidationAndroidTest') -Message "Android runtime build must publish the isolated instrumentation APK"
Assert-True -Condition $androidRuntimeBuilder.Contains('Runtime artifacts must be built from a clean committed working tree') -Message "Android runtime builds must reject dirty source"
Assert-True -Condition $androidRuntimeBuilder.Contains('zeon.android-runtime-build.v1') -Message "Android runtime builds must write provenance"
Assert-True -Condition $androidRuntimeBuilder.Contains("[string]`$BuildTarget = 'tool/android_recovery_runtime.dart'") -Message "Android runtime builds must default to the UI-free lifecycle harness"
Assert-True -Condition $androidRuntimeBuilder.Contains("'lib/main_prod.dart'") -Message "Android runtime builds must permit the isolated full-UI acceptance target"
Assert-True -Condition $androidRuntimeBuilder.Contains('zeon_android_runtime_validation=true') -Message "Android runtime builds must enable the compile-time harness guard"
Assert-True -Condition $androidRuntimeBuilder.Contains('-PzeonValidationApplicationIdSuffix=$ApplicationIdSuffix') -Message "Android runtime builds must support an isolated fresh-install application ID"
Assert-True -Condition $androidRuntimeBuilder.Contains('application_id_suffix = $ApplicationIdSuffix') -Message "Android runtime provenance must record the application ID suffix"
Assert-True -Condition $androidRuntimeBuilder.Contains('target = $BuildTarget') -Message "Android runtime provenance must record the selected build target"

$googlePlayBuilder = Get-Content -LiteralPath (Join-Path $scriptDir "build_google_play.ps1") -Raw
Assert-True -Condition $googlePlayBuilder.Contains('"appbundle"') -Message "Google Play builder must produce an Android App Bundle"
Assert-True -Condition $googlePlayBuilder.Contains('"release=google-play"') -Message "Google Play builder must hard-code the store release contract"
Assert-True -Condition $googlePlayBuilder.Contains('This build never generates or substitutes a signing identity.') -Message "Google Play builder must fail closed without the configured upload key"
Assert-True -Condition $googlePlayBuilder.Contains('Publish-ZeonFile') -Message "Google Play builder must publish through the installer path guard"

$androidGradle = Get-Content -LiteralPath (Join-Path $repoRoot "android\app\build.gradle") -Raw
Assert-True -Condition $androidGradle.Contains('project.findProperty("zeonValidationApplicationIdSuffix") ?: ".validation"') -Message "Android validation package suffix must be overridable only through the canonical build"

$runtimeLab = Get-Content -LiteralPath (Join-Path $scriptDir "windows_runtime_lab.ps1") -Raw
Assert-True -Condition $runtimeLab.Contains('BatchMode=yes') -Message "Runtime lab must use non-interactive key-only SSH"
Assert-True -Condition $runtimeLab.Contains('IdentitiesOnly=yes') -Message "Runtime lab must pin the dedicated SSH identity"
Assert-True -Condition $runtimeLab.Contains('validated immutable JSON') -Message "Runtime lab must pass run parameters through immutable JSON"
Assert-True -Condition $runtimeLab.Contains('ZEON-LAB Runtime Validation') -Message "Runtime lab must target the detached product Scheduled Task"
Assert-True -Condition $runtimeLab.Contains('CollectOnly') -Message "Runtime lab must support collection after controller disconnect"
Assert-True -Condition $runtimeLab.Contains('controller_sha = [string]$request.controller_sha') -Message "Runtime result must preserve the controller SHA frozen in the immutable request"
Assert-True -Condition $runtimeLab.Contains('TrafficUrl must be an absolute HTTPS URL.') -Message "Runtime traffic override must reject non-HTTPS targets"
Assert-True -Condition ($runtimeLab.Contains("if (Test-Path -LiteralPath '`$remoteFixtureTransfer') { Remove-Item -LiteralPath '`$remoteFixtureTransfer' -Force }; exit 0")) -Message "Fixture transfer cleanup must be idempotent after DPAPI protection"
Assert-True -Condition $runtimeLab.Contains("[switch]`$Detach") -Message "Runtime controller must support detached execution"
Assert-True -Condition $runtimeLab.Contains("[switch]`$Status") -Message "Runtime controller must support fresh-session status checks"
Assert-True -Condition $runtimeLab.Contains("[switch]`$ListRuns") -Message "Runtime controller must list immutable run summaries"
Assert-True -Condition $runtimeLab.Contains("[switch]`$Recover") -Message "Runtime controller must expose an explicit bounded recovery operation"
Assert-True -Condition $runtimeLab.Contains('DPAPI CurrentUser') -Message "Runtime controller must retain enrolled fixture material only under user DPAPI"
Assert-True -Condition (-not $runtimeLab.Contains('vm_cmd.ps1')) -Message "Remote runtime controller must not use the historical guest command bridge"
Assert-True -Condition (-not $runtimeLab.Contains('restore-clean.ps1')) -Message "Remote runtime controller must not restore a historical VM snapshot"

$runtimeRemoteRoot = Join-Path $scriptDir 'windows_runtime_lab'
$runtimeInstaller = Get-Content -LiteralPath (Join-Path $runtimeRemoteRoot 'Install-RuntimeHarness.ps1') -Raw
$runtimeRunner = Get-Content -LiteralPath (Join-Path $runtimeRemoteRoot 'Invoke-RuntimeRunner.ps1') -Raw
$runtimeWatchdog = Get-Content -LiteralPath (Join-Path $runtimeRemoteRoot 'Invoke-RuntimeWatchdog.ps1') -Raw
$runtimeRecovery = Get-Content -LiteralPath (Join-Path $runtimeRemoteRoot 'Invoke-RuntimeRecovery.ps1') -Raw
$runtimeFixture = Get-Content -LiteralPath (Join-Path $runtimeRemoteRoot 'Protect-RuntimeFixture.ps1') -Raw
Assert-True -Condition $runtimeInstaller.Contains("`$testUserName = 'ZEONRuntime'") -Message "Runtime task must use the dedicated test principal"
Assert-True -Condition $runtimeInstaller.Contains("-User `$qualifiedTestUser -Password `$passwordText -RunLevel Highest") -Message "Runtime task must use Password logon with the dedicated principal"
Assert-True -Condition $runtimeInstaller.Contains('refuse credential replacement because it would invalidate CurrentUser DPAPI') -Message "Runtime redeployment must reuse a matching Password task without replacing its credential"
Assert-True -Condition (-not $runtimeInstaller.Contains("Set-ScheduledTask -TaskName 'ZEON-LAB Runtime Validation'")) -Message "Runtime redeployment must not rewrite the Password task without its retained credential"
Assert-True -Condition $runtimeInstaller.Contains('SeDenyInteractiveLogonRight') -Message "Runtime principal must be denied local interactive logon"
Assert-True -Condition $runtimeInstaller.Contains('SeDenyRemoteInteractiveLogonRight') -Message "Runtime principal must be denied remote interactive logon"
Assert-True -Condition $runtimeInstaller.Contains("New-ScheduledTaskPrincipal -UserId 'SYSTEM'") -Message "Watchdog task must remain under SYSTEM"
Assert-True -Condition $runtimeRunner.Contains('$startInfo.CreateNoWindow = $true') -Message "Runtime process must remain windowless"
Assert-True -Condition $runtimeRunner.Contains("@('preflight', 'connect', 's02', 's06', 'manual-proxy', 'auto-proxy', 'p03-r17', 'p04')") -Message "Remote runner must enable the bounded acceptance scenario set"
Assert-True -Condition $runtimeRunner.Contains("@('system-proxy', 'tun', 'local-proxy')") -Message "Remote runner must enable every supported Windows network mode"
Assert-True -Condition $runtimeRunner.Contains("@('ipv4_only', 'prefer_ipv4', 'prefer_ipv6', 'ipv6_only')") -Message "Remote runner must enable every supported IPv6 mode"
Assert-True -Condition $runtimeRunner.Contains("`$currentSid -cne `$expectedSid") -Message "Remote runner must verify its dedicated runtime identity"
Assert-True -Condition $runtimeWatchdog.Contains('arming_valid') -Message "Watchdog apply mode must require a run-scoped arming manifest"
Assert-True -Condition $runtimeRecovery.Contains('Stop-RuntimeOwnedProcesses') -Message "Recovery must stop only explicitly recorded lab-owned processes"
Assert-True -Condition (-not ($runtimeRecovery -match '(?i)shutdown\.exe|Restart-Computer')) -Message "Runtime recovery must never reboot automatically"
Assert-True -Condition $runtimeFixture.Contains('DataProtectionScope]::LocalMachine') -Message "Fixture must be encrypted outside evidence with machine DPAPI"
Assert-True -Condition $runtimeFixture.Contains('Add-Type -AssemblyName System.Security') -Message "Fixture protection must load the Windows DPAPI assembly"
Assert-True -Condition $runtimeRunner.Contains('Add-Type -AssemblyName System.Security') -Message "Fixture unprotection must load the Windows DPAPI assembly"

$runtimeHarness = Get-Content -LiteralPath (Join-Path $repoRoot "tool\windows_recovery_runtime.dart") -Raw
Assert-True -Condition $runtimeHarness.Contains('connectionNotifierProvider.notifier') -Message "Runtime harness must use the application lifecycle owner"
Assert-True -Condition ($runtimeHarness -notmatch '(?i)sendkeys|findwindow|pyautogui|\.click\(') -Message "Runtime harness must not contain UI automation"

$windowsPackager = Get-Content -LiteralPath (Join-Path $scriptDir "package_windows_installers.ps1") -Raw
Assert-True -Condition $windowsPackager.Contains('[System.IO.Path]::GetTempPath()') -Message "Windows packaging needs a portable CI temp fallback"
Assert-True -Condition (-not $windowsPackager.Contains('cmd /c')) -Message "Windows packaging must invoke robocopy directly"
Assert-True -Condition $windowsPackager.Contains('ZEON-Windows-Setup-x64-unsigned.exe') -Message "Unsigned EXE packaging must use a distinct artifact name"

$commonBuild = Get-Content -LiteralPath $commonPath -Raw
Assert-True -Condition $commonBuild.Contains('Get-Command "flutter"') -Message "Pinned Flutter resolver must accept an exact SDK already in PATH"
Assert-True -Condition $commonBuild.Contains('Z:\Zeon-Envelope\Temp\wz') -Message "Canonical Windows workspace must use the short ZEON Temp root"
Assert-True -Condition (-not (Test-ZeonWindowsPathHasFlutterBlockedCharacters -PathToCheck 'Z:\Zeon-Envelope\Projects\zeon-app')) -Message "Canonical repo path must not spuriously trigger a junction"
Assert-True -Condition (Test-ZeonWindowsPathHasFlutterBlockedCharacters -PathToCheck 'Z:\build#blocked') -Message "Flutter-blocked path characters must trigger a junction"
Assert-True -Condition ((Get-ZeonShortWindowsWorkspaceRoot -RepoRoot $repoRoot) -eq 'Z:\Zeon-Envelope\Temp\wz') -Message "Canonical Windows builds must use the short ZEON Temp root"

Write-Host "Build entrypoint tests passed."
