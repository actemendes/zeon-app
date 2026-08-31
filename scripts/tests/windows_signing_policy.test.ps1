[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptsDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$repoRoot = Split-Path -Parent $scriptsDir
$scriptPath = Join-Path $scriptsDir 'package_windows_installers.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    throw "Signing script parser errors: $($errors | Out-String)"
}

$content = Get-Content -LiteralPath $scriptPath -Raw
$makeContent = Get-Content -LiteralPath (Join-Path $repoRoot 'Makefile') -Raw
$workflowContent = Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\build.yml') -Raw
$requiredPatterns = [ordered]@{
    timestamp_argument = '/tr'
    timestamp_required = 'timestamp URL is required'
    timestamp_verified = 'TimeStamperCertificate'
    recursive_payload_enumeration = 'Get-ChildItem -LiteralPath $ReleaseDir -Recurse -File'
    required_ui_binary = "'ZEON.exe'"
    required_cli_binary = "'ZEONCli.exe'"
    invalid_signature_rejected = 'Refusing to package binary with invalid signature'
    signer_consistency = 'ExpectedThumbprint'
    sha256_manifest = 'Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256'
    local_dev_only = 'main_dev\.dart$'
    ci_guard = '$env:CI'
    portable_target = 'ZEON-Windows-Portable-x64.zip'
    msix_final_signing = 'Invoke-AuthenticodeSigning'
    nested_payload_verification = 'Assert-WindowsArchivePayloadSignatures'
}

foreach ($entry in $requiredPatterns.GetEnumerator()) {
    if ($content -notmatch [regex]::Escape($entry.Value)) {
        throw "Signing policy self-test failed: missing $($entry.Key)"
    }
}

$relativePathFunction = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-ReleaseRelativePath'
}, $true)
if ($relativePathFunction.Count -ne 1) {
    throw 'Signing policy self-test failed: PowerShell 5.1 relative-path helper is missing.'
}
if ($content -match '\[System\.IO\.Path\]::GetRelativePath') {
    throw 'Signing policy self-test failed: unsupported Path.GetRelativePath is still used.'
}
if ($makeContent -notmatch '(?m)^windows-release:\s*\r?\n\s*powershell.+package_windows_installers\.ps1') {
    throw 'Signing policy self-test failed: Windows release does not use the fail-closed packager.'
}
if ($workflowContent -notmatch 'ZEON_WINDOWS_SIGNING_PFX' -or
    $workflowContent -match 'zeon/signtool-code-sign-sha256') {
    throw 'Signing policy self-test failed: CI signing inputs/final-artifact ordering are unsafe.'
}

Write-Output 'Windows signing policy self-tests passed.'
