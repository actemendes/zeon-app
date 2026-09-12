[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$FixtureId,
    [Parameter(Mandatory = $true)][string]$ExpectedSha256,
    [string]$SecretRoot = "$env:ProgramData\ZEON-LAB-Secrets",
    [string]$LabRoot = 'C:\ZEON-LAB'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RuntimeLab.Common.ps1')
Add-Type -AssemblyName System.Security
Assert-RuntimeSafeId -Value $FixtureId -Label 'fixture_id'
if ($ExpectedSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'Invalid fixture SHA-256.' }
if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw 'Fixture transfer file is missing.' }

New-Item -ItemType Directory -Path $SecretRoot -Force | Out-Null
$deployment = Get-Content -LiteralPath (Join-Path $LabRoot 'state\runtime\deployment.json') -Raw | ConvertFrom-Json
$testUserSid = [string]$deployment.task.sid
if ($testUserSid -notmatch '^S-1-5-21-(?:\d+-){3}\d+$') { throw 'Runtime test principal SID is unavailable.' }
Set-RuntimeRestrictedAcl -Path $SecretRoot -AdditionalFullControlSids @($testUserSid)
$destination = Join-Path $SecretRoot ("{0}.dpapi" -f $FixtureId)
if (Test-Path -LiteralPath $destination) { throw 'Encrypted fixture id already exists.' }
$completed = $false
try {
    $actual = Get-RuntimeFileHash -Path $SourcePath
    if ($actual -cne $ExpectedSha256.ToLowerInvariant()) { throw 'Fixture transfer SHA-256 mismatch.' }
    $plain = [IO.File]::ReadAllBytes($SourcePath)
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect($plain, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        [IO.File]::WriteAllBytes($destination, $protected)
        Set-RuntimeRestrictedAcl -Path $destination -AdditionalFullControlSids @($testUserSid)
        $completed = $true
    } finally {
        [Array]::Clear($plain, 0, $plain.Length)
    }
} finally {
    Remove-Item -LiteralPath $SourcePath -Force -ErrorAction SilentlyContinue
    if (-not $completed) { Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue }
}
[ordered]@{ fixture_id = $FixtureId; sha256 = $ExpectedSha256.ToLowerInvariant(); storage = 'DPAPI LocalMachine'; plaintext_retained = $false } | ConvertTo-Json
