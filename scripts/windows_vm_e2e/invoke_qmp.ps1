[CmdletBinding()]
param(
    [int]$Port = 54444,
    [Parameter(Mandatory = $true)][string]$Execute,
    [string]$ArgumentsJson = "{}"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Read-QmpResponse {
    param([Parameter(Mandatory = $true)][IO.StreamReader]$Reader)
    while ($true) {
        $line = $Reader.ReadLine()
        if ($null -eq $line) {
            throw "QMP disconnected before returning a response."
        }
        $value = $line | ConvertFrom-Json
        if ($value.PSObject.Properties.Name -contains "return" -or
            $value.PSObject.Properties.Name -contains "error") {
            return $value
        }
    }
}

$client = [Net.Sockets.TcpClient]::new()
try {
    $client.Connect("127.0.0.1", $Port)
    $stream = $client.GetStream()
    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $false, 4096, $true)
    $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false), 4096, $true)
    $writer.NewLine = "`n"
    $writer.AutoFlush = $true

    $greeting = $reader.ReadLine() | ConvertFrom-Json
    if (-not ($greeting.PSObject.Properties.Name -contains "QMP")) {
        throw "QMP greeting was not received."
    }
    $writer.WriteLine('{"execute":"qmp_capabilities"}')
    $capabilities = Read-QmpResponse -Reader $reader
    if ($capabilities.PSObject.Properties.Name -contains "error") {
        throw "QMP capability negotiation failed: $($capabilities | ConvertTo-Json -Compress)"
    }

    $arguments = $ArgumentsJson | ConvertFrom-Json
    $request = @{ execute = $Execute; arguments = $arguments } | ConvertTo-Json -Compress -Depth 10
    $writer.WriteLine($request)
    $response = Read-QmpResponse -Reader $reader
    $response | ConvertTo-Json -Depth 10
    if ($response.PSObject.Properties.Name -contains "error") {
        exit 1
    }
}
finally {
    $client.Dispose()
}
