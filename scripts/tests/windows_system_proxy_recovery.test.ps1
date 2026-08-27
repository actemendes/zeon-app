[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Join-Path $repoRoot "windows\runner\system_proxy_recovery_logic_test.cpp"
$registrySource = Join-Path $repoRoot "windows\runner\system_proxy_recovery_registry_test.cpp"
$includeDir = Join-Path $repoRoot "windows\runner"
$vcVarsCandidates = @(
    "C:\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
    "${env:ProgramFiles}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
    "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
)
$vcVars = $vcVarsCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $vcVars) {
    throw "Visual C++ vcvars64.bat was not found."
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("zeon-proxy-recovery-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    $output = Join-Path $tempDir "windows_system_proxy_recovery_test.exe"
    $object = Join-Path $tempDir "windows_system_proxy_recovery_test.obj"
    $command = '"{0}" >nul && cl.exe /nologo /std:c++17 /W4 /WX /EHsc /I"{1}" "{2}" /Fo:"{3}" /Fe:"{4}"' -f `
        $vcVars, $includeDir, $source, $object, $output
    & cmd.exe /d /c $command
    if ($LASTEXITCODE -ne 0) {
        throw "System-proxy recovery decision test compilation failed."
    }
    & $output
    if ($LASTEXITCODE -ne 0) {
        throw "System-proxy recovery decision tests failed with exit code $LASTEXITCODE."
    }

    $registryOutput = Join-Path $tempDir "windows_system_proxy_recovery_registry_test.exe"
    $registryObject = Join-Path $tempDir "windows_system_proxy_recovery_registry_test.obj"
    $registryCommand = '"{0}" >nul && cl.exe /nologo /std:c++17 /W4 /WX /EHsc /I"{1}" "{2}" /Fo:"{3}" /Fe:"{4}" /link advapi32.lib' -f `
        $vcVars, $includeDir, $registrySource, $registryObject, $registryOutput
    & cmd.exe /d /c $registryCommand
    if ($LASTEXITCODE -ne 0) {
        throw "System-proxy recovery registry test compilation failed."
    }
    & $registryOutput
    if ($LASTEXITCODE -ne 0) {
        throw "System-proxy recovery registry test failed with exit code $LASTEXITCODE."
    }

    $packager = Get-Content -Raw (Join-Path $repoRoot "scripts\package_windows_installers.ps1")
    if ($packager -notmatch '\[UninstallRun\]' -or
        $packager -notmatch '--recover-system-proxy' -or
        $packager -notmatch 'waituntilterminated' -or
        $packager -notmatch 'RunOnceId: "ZEONSystemProxyRecovery"') {
        throw "Windows installer does not run system-proxy recovery before deleting ZEON."
    }
    $runnerMain = Get-Content -Raw (Join-Path $repoRoot "windows\runner\main.cpp")
    if ($runnerMain -notmatch 'RecoverZeonSystemProxy\(false\)' -or
        $runnerMain -notmatch '--recover-system-proxy') {
        throw "Windows runner early system-proxy recovery is missing."
    }
    $coreProxy = Get-Content -Raw (Join-Path $repoRoot "hiddify-core\hiddify-sing-box\common\settings\proxy_windows.go")
    if ($coreProxy -match 'ClearSystemProxy') {
        throw "Windows core still contains an unconditional system-proxy clear."
    }
    $invalidateIndex = $coreProxy.IndexOf('SetDWordValue("Armed", 0)')
    $commitIndex = $coreProxy.LastIndexOf('SetDWordValue("Armed", 1)')
    if ($invalidateIndex -lt 0 -or $commitIndex -le $invalidateIndex) {
        throw "Windows proxy ownership marker is not written with an Armed=0/Armed=1 two-phase commit."
    }
    $nativeRecovery = Get-Content -Raw (Join-Path $repoRoot "windows\runner\system_proxy_recovery.cpp")
    if ($nativeRecovery -notmatch 'ReadQword\(key\.get\(\), L"Generation"' -or
        $nativeRecovery -notmatch 'record->generation == 0') {
        throw "Native startup recovery does not require a non-zero ownership generation."
    }
    Write-Host "Windows system-proxy recovery decision and registry tests: PASS"
}
finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
