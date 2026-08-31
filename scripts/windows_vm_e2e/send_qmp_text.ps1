[CmdletBinding()]
param(
    [int]$Port = 54444,
    [Parameter(Mandatory = $true)][string]$Text,
    [ValidateRange(30, 250)][int]$InterKeyDelayMilliseconds = 40,
    [switch]$PressEnter
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$keyMap = @{
    ' ' = @('spc')
    '\' = @('backslash')
    '/' = @('slash')
    '-' = @('minus')
    '_' = @('shift', 'minus')
    '.' = @('dot')
    ':' = @('shift', 'semicolon')
    ';' = @('semicolon')
    '"' = @('shift', 'apostrophe')
    "'" = @('apostrophe')
    '=' = @('equal')
    '+' = @('shift', 'equal')
    '@' = @('shift', '2')
    '$' = @('shift', '4')
    '%' = @('shift', '5')
    '&' = @('shift', '7')
    '*' = @('shift', '8')
    '(' = @('shift', '9')
    ')' = @('shift', '0')
    '[' = @('bracket_left')
    ']' = @('bracket_right')
    '{' = @('shift', 'bracket_left')
    '}' = @('shift', 'bracket_right')
    ',' = @('comma')
    '<' = @('shift', 'comma')
    '>' = @('shift', 'dot')
    '?' = @('shift', 'slash')
    '|' = @('shift', 'backslash')
}

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

function Send-QmpKeys {
    param(
        [Parameter(Mandatory = $true)][IO.StreamWriter]$Writer,
        [Parameter(Mandatory = $true)][IO.StreamReader]$Reader,
        [Parameter(Mandatory = $true)][string[]]$Keys
    )
    $events = @($Keys | ForEach-Object {
        @{ type = 'qcode'; data = $_ }
    })
    $request = @{
        execute = 'send-key'
        arguments = @{ keys = $events; 'hold-time' = 25 }
    } | ConvertTo-Json -Compress -Depth 8
    $Writer.WriteLine($request)
    $response = Read-QmpResponse -Reader $Reader
    if ($response.PSObject.Properties.Name -contains 'error') {
        throw "QMP key input failed: $($response | ConvertTo-Json -Compress)"
    }
}

$client = [Net.Sockets.TcpClient]::new()
try {
    $client.Connect('127.0.0.1', $Port)
    $stream = $client.GetStream()
    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $false, 4096, $true)
    $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false), 4096, $true)
    $writer.NewLine = "`n"
    $writer.AutoFlush = $true

    $greeting = $reader.ReadLine() | ConvertFrom-Json
    if (-not ($greeting.PSObject.Properties.Name -contains 'QMP')) {
        throw 'QMP greeting was not received.'
    }
    $writer.WriteLine('{"execute":"qmp_capabilities"}')
    $capabilities = Read-QmpResponse -Reader $reader
    if ($capabilities.PSObject.Properties.Name -contains 'error') {
        throw 'QMP capability negotiation failed.'
    }

    foreach ($character in $Text.ToCharArray()) {
        $string = [string]$character
        if ($keyMap.ContainsKey($string)) {
            Send-QmpKeys -Writer $writer -Reader $reader -Keys $keyMap[$string]
        } elseif ($string -cmatch '^[A-Z]$') {
            Send-QmpKeys -Writer $writer -Reader $reader -Keys @('shift', $string.ToLowerInvariant())
        } elseif ($string -match '^[a-z0-9]$') {
            Send-QmpKeys -Writer $writer -Reader $reader -Keys @($string.ToLowerInvariant())
        } else {
            throw "Unsupported QMP text character: $string"
        }
        Start-Sleep -Milliseconds $InterKeyDelayMilliseconds
    }
    if ($PressEnter) {
        Send-QmpKeys -Writer $writer -Reader $reader -Keys @('ret')
    }
}
finally {
    $client.Dispose()
}
