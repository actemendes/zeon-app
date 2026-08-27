[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CredentialPath,
    [Parameter(Mandatory = $true)][string]$PythonPath,
    [Parameter(Mandatory = $true)][string]$Script,
    [ValidateSet("Admin", "Test")][string]$CredentialName = "Test",
    [string]$UserName = "zeontest",
    [ValidateRange(1, 65535)][int]$Port = 55985,
    [ValidateRange(1, 300)][int]$OperationTimeoutSeconds = 30,
    [ValidateRange(2, 330)][int]$ReadTimeoutSeconds = 35
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

foreach ($required in @($CredentialPath, $PythonPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required VM WinRM input was not found: $required"
    }
}
if ($ReadTimeoutSeconds -le $OperationTimeoutSeconds) {
    throw "ReadTimeoutSeconds must be greater than OperationTimeoutSeconds."
}

$stored = Import-Clixml -LiteralPath $CredentialPath
$securePassword = $stored.PSObject.Properties[$CredentialName].Value
if ($securePassword -isnot [securestring]) {
    throw "Credential '$CredentialName' was not found in the DPAPI credential file."
}
$password = [pscredential]::new($UserName, $securePassword).GetNetworkCredential().Password
$encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))

$env:ZEON_VM_WINRM_PASSWORD = $password
$env:ZEON_VM_WINRM_SCRIPT = $encodedScript
$env:ZEON_VM_WINRM_USER = $UserName
$env:ZEON_VM_WINRM_PORT = $Port.ToString([Globalization.CultureInfo]::InvariantCulture)
$env:ZEON_VM_WINRM_OPERATION_TIMEOUT = $OperationTimeoutSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)
$env:ZEON_VM_WINRM_READ_TIMEOUT = $ReadTimeoutSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)
$previousNoProxy = $env:NO_PROXY
$env:NO_PROXY = "127.0.0.1,localhost"

try {
    $python = @'
import base64
import json
import os
import sys

import winrm

try:
    session = winrm.Session(
        "http://127.0.0.1:%s/wsman" % os.environ["ZEON_VM_WINRM_PORT"],
        auth=(os.environ["ZEON_VM_WINRM_USER"], os.environ["ZEON_VM_WINRM_PASSWORD"]),
        transport="basic",
        operation_timeout_sec=int(os.environ["ZEON_VM_WINRM_OPERATION_TIMEOUT"]),
        read_timeout_sec=int(os.environ["ZEON_VM_WINRM_READ_TIMEOUT"]),
    )
    result = session.run_cmd(
        "powershell.exe",
        ["-NoProfile", "-NonInteractive", "-EncodedCommand", os.environ["ZEON_VM_WINRM_SCRIPT"]],
    )
    payload = {
        "status_code": result.status_code,
        "stdout_base64": base64.b64encode(result.std_out).decode("ascii"),
        "stderr_base64": base64.b64encode(result.std_err).decode("ascii"),
    }
except Exception as error:
    payload = {
        "client_error": type(error).__name__,
        "status_code": -1,
        "stdout_base64": "",
        "stderr_base64": "",
    }
sys.stdout.write(json.dumps(payload))
'@
    $raw = $python | & $PythonPath -
    if ($LASTEXITCODE -ne 0) {
        throw "VM WinRM client failed with exit code $LASTEXITCODE."
    }
    $result = $raw | ConvertFrom-Json
    if ($result.PSObject.Properties.Name -contains "client_error") {
        throw "VM WinRM connection failed: $($result.client_error)."
    }
    $stdout = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($result.stdout_base64))
    $stderr = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($result.stderr_base64))
    [pscustomobject]@{
        StatusCode = [int]$result.status_code
        StdOut = $stdout
        StdErr = $stderr
    }
}
finally {
    $password = $null
    Remove-Item Env:ZEON_VM_WINRM_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:ZEON_VM_WINRM_SCRIPT -ErrorAction SilentlyContinue
    Remove-Item Env:ZEON_VM_WINRM_USER -ErrorAction SilentlyContinue
    Remove-Item Env:ZEON_VM_WINRM_PORT -ErrorAction SilentlyContinue
    Remove-Item Env:ZEON_VM_WINRM_OPERATION_TIMEOUT -ErrorAction SilentlyContinue
    Remove-Item Env:ZEON_VM_WINRM_READ_TIMEOUT -ErrorAction SilentlyContinue
    if ($null -eq $previousNoProxy) {
        Remove-Item Env:NO_PROXY -ErrorAction SilentlyContinue
    } else {
        $env:NO_PROXY = $previousNoProxy
    }
}
