[CmdletBinding()]
param(
    [ValidateSet("Preflight", "Initialize", "RunPreset", "Finalize")]
    [string]$Action = "Preflight",

    [string]$Serial,

    [string]$AdbPath,

    [ValidateSet("Direct", "Russia", "Global")]
    [string]$Preset,

    [string]$SessionPath,

    [string]$OutputRoot = ".codex-artifacts/stage2.8-ru-browser",

    [string]$ExpectedModel = "GM1901",

    [int]$ExpectedSdk = 36,

    [string]$BrowserPackage = "com.android.chrome",

    [string]$ZeonPackage = "com.zeon.hiddify.validation",

    # Evidence label only. The harness never mutates ZEON's runtime DNS policy.
    [ValidateSet("DIRECT_DNS", "REMOTE_DNS_BASELINE")]
    [string]$DnsVariant = "DIRECT_DNS",

    [string]$BuildLabel = "stage2.8-validation",

    [ValidateRange(0, 180)]
    [int]$SettleSeconds = 15
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:TelemetryPrefix = "ZEON_ROUTE_VALIDATION "
$script:RequiredTelemetryFields = @(
    "kind",
    "hostname",
    "resolvedIpHash",
    "ipVersion",
    "matchedRule",
    "matchedRuleSet",
    "route",
    "dns",
    "protocol",
    "generation"
)

function Get-Stage28Sites {
    $catalog = @'
Id,Name,Url,Kind,Applicable
gosuslugi,Gosuslugi,https://www.gosuslugi.ru/,mandatory,visual;js;css;images;api;cdn;redirects
esia,ESIA,https://esia.gosuslugi.ru/,mandatory,visual;js;css;images;api;cdn;redirects
nalog,Nalog,https://www.nalog.gov.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search
mos,Mos.ru,https://www.mos.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search
cbr,Central Bank,https://cbr.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search
sbp,SBP,https://sbp.nspk.ru/,mandatory,visual;js;css;images;api;cdn;redirects
sber,Sber,https://www.sberbank.ru/ru/person,mandatory,visual;js;css;images;api;cdn;redirects;publicCards
tbank,T-Bank,https://www.tbank.ru/,mandatory,visual;js;css;images;api;cdn;redirects;publicCards
alfa,Alfa-Bank,https://alfabank.ru/,mandatory,visual;js;css;images;api;cdn;redirects;publicCards
vtb,VTB,https://www.vtb.ru/,mandatory,visual;js;css;images;api;cdn;redirects;publicCards
gazprombank,Gazprombank,https://www.gazprombank.ru/,mandatory,visual;js;css;images;api;cdn;redirects;publicCards
yandex,Yandex,https://yandex.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search;webSocket
yandex_search,Yandex Search,https://yandex.ru/search/?text=ZEON%20Stage%202.8,mandatory,visual;js;css;images;api;cdn;redirects;search
yandex_maps,Yandex Maps,https://yandex.ru/maps/,mandatory,visual;js;css;images;api;cdn;redirects;search;webSocket
yandex_music,Yandex Music,https://music.yandex.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search;video;webSocket
kinopoisk,Kinopoisk,https://www.kinopoisk.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search;publicCards;video
wildberries,Wildberries,https://www.wildberries.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search;publicCards;webSocket
ozon,Ozon,https://www.ozon.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search;publicCards;webSocket
avito,Avito,https://www.avito.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search;publicCards;webSocket
megamarket,Megamarket,https://megamarket.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search;publicCards
yandex_market,Yandex Market,https://market.yandex.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search;publicCards;webSocket
vk,VK,https://vk.com/,mandatory,visual;js;css;images;api;cdn;redirects;publicCards;video;webSocket
mail,Mail.ru,https://mail.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search;publicCards
ok,OK,https://ok.ru/,mandatory,visual;js;css;images;api;cdn;redirects;publicCards;video;webSocket
dzen,Dzen,https://dzen.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search;publicCards;video
twogis,2GIS,https://2gis.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search;publicCards;webSocket
rutube,Rutube,https://rutube.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search;publicCards;video
rustore,RuStore,https://www.rustore.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search;publicCards
rzd,RZD,https://www.rzd.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search
aeroflot,Aeroflot,https://www.aeroflot.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search
hh,HH,https://hh.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search;publicCards;webSocket
ria,RIA,https://ria.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search;publicCards;video
lenta,Lenta,https://lenta.ru/,mandatory,visual;js;css;images;api;cdn;redirects;search;publicCards;video
ru_public_exit,RU public exit,https://2ip.ru/,diagnostic,publicExit;country;asn;asnCategory;ipv4;ipv6;vpnWarnings;captcha;rateLimit
global_public_exit,Global public exit,https://ipinfo.io/,diagnostic,publicExit;country;asn;asnCategory;ipv4;ipv6;vpnWarnings;captcha;rateLimit
ipv6,IPv6,https://test-ipv6.com/,diagnostic,ipv4;ipv6
dns_region,DNS region,https://browserleaks.com/dns,diagnostic,dnsRegion
webrtc,WebRTC,https://browserleaks.com/webrtc,diagnostic,webrtc;ipv4;ipv6
browser_consistency,Timezone and language,https://browserleaks.com/javascript,diagnostic,timezone;language
su_suffix,.su suffix route,https://ripn.su/,diagnostic,suffixRoute
rf_suffix,.xn--p1ai suffix route,https://xn--80aa3ak5a.xn--p1ai/,diagnostic,suffixRoute
'@
    return @($catalog | ConvertFrom-Csv)
}

function Resolve-Adb {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($AdbPath) {
        if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
            throw "Explicit -AdbPath does not exist: $AdbPath"
        }
        $explicitAdb = (Resolve-Path -LiteralPath $AdbPath).Path
        if ([System.IO.Path]::GetExtension($explicitAdb) -in @(".cmd", ".bat")) {
            throw "-AdbPath must name the ADB executable, not a cmd/bat wrapper: $explicitAdb"
        }
        return $explicitAdb
    }
    foreach ($commandName in @("adb.exe", "adb")) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($null -ne $command -and $command.Source) {
            $candidates.Add($command.Source)
        }
    }
    foreach ($sdkRoot in @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)) {
        if (-not $sdkRoot) {
            continue
        }
        $candidates.Add((Join-Path $sdkRoot "platform-tools/adb.exe"))
        $candidates.Add((Join-Path $sdkRoot "platform-tools/adb"))
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        $resolved = (Resolve-Path -LiteralPath $candidate).Path
        if ([System.IO.Path]::GetExtension($resolved) -in @(".cmd", ".bat")) {
            continue
        }
        return $resolved
    }
    throw "ADB executable was not found. Use -AdbPath or set ANDROID_SDK_ROOT/ANDROID_HOME."
}

function Assert-SafeSerial {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -notmatch '^[A-Za-z0-9._:-]+$') {
        throw "Unsafe or unsupported ADB serial: $Value"
    }
}

function Invoke-Adb {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = @(& $script:AdbPath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "ADB failed ($exitCode): adb $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines = $output
        Text = ($output -join [Environment]::NewLine)
    }
}

function Invoke-DeviceAdb {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $allArguments = @("-s", $script:DeviceSerial) + $Arguments
    return Invoke-Adb -Arguments $allArguments -AllowFailure:$AllowFailure
}

function Get-StringSha256 {
    param([Parameter(Mandatory = $true)][string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $script:Utf8NoBom.GetBytes($Value)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 12
    )

    $json = $Value | ConvertTo-Json -Depth $Depth
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $script:Utf8NoBom)
}

function Get-PackageVersion {
    param([Parameter(Mandatory = $true)][string]$PackageName)

    $dump = Invoke-DeviceAdb -Arguments @("shell", "dumpsys", "package", $PackageName)
    $versionName = ""
    $versionCode = ""
    foreach ($line in $dump.Lines) {
        if (-not $versionName -and $line -match 'versionName=([^\s]+)') {
            $versionName = $Matches[1]
        }
        if (-not $versionCode -and $line -match 'versionCode=(\d+)') {
            $versionCode = $Matches[1]
        }
    }
    return [ordered]@{
        package = $PackageName
        versionName = $versionName
        versionCode = $versionCode
    }
}

function Get-InstalledApkEvidence {
    param([Parameter(Mandatory = $true)][string]$PackageName)

    if ($PackageName -notmatch '\.validation$') {
        throw "Stage 2.8 browser evidence must use an isolated .validation package, got: $PackageName"
    }

    $packagePathResult = Invoke-DeviceAdb -Arguments @("shell", "pm", "path", $PackageName)
    $basePathLine = @($packagePathResult.Lines | Where-Object { $_ -match '^package:.*base\.apk$' }) | Select-Object -First 1
    if (-not $basePathLine) {
        throw "Unable to resolve installed base.apk for $PackageName."
    }
    $deviceApkPath = $basePathLine.Substring("package:".Length)

    $temporaryApk = Join-Path ([System.IO.Path]::GetTempPath()) ("zeon-stage28-" + [guid]::NewGuid().ToString("N") + ".apk")
    try {
        $pull = Invoke-DeviceAdb -Arguments @("pull", $deviceApkPath, $temporaryApk)
        if (-not (Test-Path -LiteralPath $temporaryApk)) {
            throw "ADB reported success but did not pull the installed APK."
        }
        $apkHash = (Get-FileHash -LiteralPath $temporaryApk -Algorithm SHA256).Hash.ToLowerInvariant()

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($temporaryApk)
        try {
            $coreEntries = @($archive.Entries | Where-Object {
                $_.FullName -match '^lib/[^/]+/libhiddify-core\.so$'
            })
            if ($coreEntries.Count -eq 0) {
                throw "The installed APK has no libhiddify-core.so."
            }
            $markerFound = $false
            foreach ($entry in $coreEntries) {
                $entryStream = $entry.Open()
                try {
                    $memory = New-Object System.IO.MemoryStream
                    try {
                        $entryStream.CopyTo($memory)
                        $ascii = [System.Text.Encoding]::ASCII.GetString($memory.ToArray())
                        if ($ascii.Contains($script:TelemetryPrefix)) {
                            $markerFound = $true
                            break
                        }
                    } finally {
                        $memory.Dispose()
                    }
                } finally {
                    $entryStream.Dispose()
                }
            }
            if (-not $markerFound) {
                throw "Installed APK does not contain validation-only ZEON route telemetry."
            }
        } finally {
            $archive.Dispose()
        }

        return [ordered]@{
            package = $PackageName
            apkSha256 = $apkHash
            validationTelemetryMarker = $true
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryApk) {
            Remove-Item -LiteralPath $temporaryApk -Force
        }
    }
}

function Invoke-Stage28Preflight {
    $devices = Invoke-Adb -Arguments @("devices", "-l")
    $connected = @()
    foreach ($line in $devices.Lines) {
        if ($line -match '^([^\s]+)\s+(device|offline|unauthorized)\b(.*)$') {
            $connected += [pscustomobject]@{
                Serial = $Matches[1]
                State = $Matches[2]
                Details = $Matches[3]
            }
        }
    }

    if ($Serial) {
        Assert-SafeSerial -Value $Serial
        $selected = @($connected | Where-Object { $_.Serial -eq $Serial })
        if ($selected.Count -ne 1) {
            throw "Expected ADB device '$Serial' is absent."
        }
        $device = $selected[0]
    } else {
        $ready = @($connected | Where-Object { $_.State -eq "device" })
        if ($ready.Count -ne 1) {
            throw "Expected exactly one authorized physical ADB device; found $($ready.Count). Use -Serial if needed."
        }
        $device = $ready[0]
    }
    if ($device.State -ne "device") {
        throw "ADB device '$($device.Serial)' is $($device.State), not ready."
    }
    $script:DeviceSerial = $device.Serial
    Assert-SafeSerial -Value $script:DeviceSerial

    $model = (Invoke-DeviceAdb -Arguments @("shell", "getprop", "ro.product.model")).Text.Trim()
    $manufacturer = (Invoke-DeviceAdb -Arguments @("shell", "getprop", "ro.product.manufacturer")).Text.Trim()
    $sdk = (Invoke-DeviceAdb -Arguments @("shell", "getprop", "ro.build.version.sdk")).Text.Trim()
    $release = (Invoke-DeviceAdb -Arguments @("shell", "getprop", "ro.build.version.release")).Text.Trim()
    $abi = (Invoke-DeviceAdb -Arguments @("shell", "getprop", "ro.product.cpu.abi")).Text.Trim()
    if ($model -ne $ExpectedModel) {
        throw "Wrong physical device: expected model $ExpectedModel, got '$model'."
    }
    if ($sdk -ne $ExpectedSdk.ToString()) {
        throw "Wrong Android API level on ${model}: expected $ExpectedSdk, got '$sdk'."
    }

    foreach ($packageName in @($BrowserPackage, $ZeonPackage)) {
        $packages = Invoke-DeviceAdb -Arguments @("shell", "pm", "list", "packages", $packageName)
        if (@($packages.Lines | Where-Object { $_.Trim() -eq "package:$packageName" }).Count -ne 1) {
            throw "Required package is absent on ${model}: $packageName"
        }
    }
    $resolvedBrowser = Invoke-DeviceAdb -Arguments @(
        "shell", "cmd", "package", "resolve-activity", "--brief",
        "-a", "android.intent.action.VIEW", "-d", "https://example.com/", "-p", $BrowserPackage
    )
    if ($resolvedBrowser.Text -notmatch [regex]::Escape($BrowserPackage + "/")) {
        throw "Chrome cannot resolve a normal HTTPS browser intent: $($resolvedBrowser.Text)"
    }

    $apkEvidence = Get-InstalledApkEvidence -PackageName $ZeonPackage
    $script:Preflight = [ordered]@{
        capturedAtUtc = [DateTime]::UtcNow.ToString("o")
        device = [ordered]@{
            serialSha256 = Get-StringSha256 -Value $script:DeviceSerial
            manufacturer = $manufacturer
            model = $model
            androidRelease = $release
            sdk = [int]$sdk
            abi = $abi
        }
        browser = Get-PackageVersion -PackageName $BrowserPackage
        zeon = Get-PackageVersion -PackageName $ZeonPackage
        installedArtifact = $apkEvidence
    }
    return $script:Preflight
}

function Resolve-OutputRoot {
    if ([System.IO.Path]::IsPathRooted($OutputRoot)) {
        return [System.IO.Path]::GetFullPath($OutputRoot)
    }
    $repoRoot = Split-Path -Parent $PSScriptRoot
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputRoot))
}

function New-ObservationRows {
    $rows = @()
    foreach ($currentPreset in @("Direct", "Russia", "Global")) {
        foreach ($site in Get-Stage28Sites) {
            $applicable = @($site.Applicable -split ';')
            $isMandatory = $site.Kind -eq "mandatory"
            $requiresRouteTelemetry = $isMandatory -or $applicable -contains "suffixRoute"
            $rows += [pscustomobject][ordered]@{
                Preset = $currentPreset
                SiteId = $site.Id
                Name = $site.Name
                Status = if ($isMandatory) { "NOT_REVIEWED" } else { "NOT_RECORDED" }
                VisualLoad = if ($isMandatory) { "NOT_REVIEWED" } else { "NOT_APPLICABLE" }
                JavaScript = if ($applicable -contains "js") { "NOT_REVIEWED" } else { "NOT_APPLICABLE" }
                CSS = if ($applicable -contains "css") { "NOT_REVIEWED" } else { "NOT_APPLICABLE" }
                Images = if ($applicable -contains "images") { "NOT_REVIEWED" } else { "NOT_APPLICABLE" }
                API = if ($applicable -contains "api") { "NOT_REVIEWED" } else { "NOT_APPLICABLE" }
                CDN = if ($applicable -contains "cdn") { "NOT_REVIEWED" } else { "NOT_APPLICABLE" }
                Redirects = if ($applicable -contains "redirects") { "NOT_REVIEWED" } else { "NOT_APPLICABLE" }
                Search = if ($applicable -contains "search") { "NOT_REVIEWED" } else { "NOT_APPLICABLE" }
                PublicCards = if ($applicable -contains "publicCards") { "NOT_REVIEWED" } else { "NOT_APPLICABLE" }
                VideoPreviewPlayback = if ($applicable -contains "video") { "NOT_REVIEWED" } else { "NOT_APPLICABLE" }
                WebSocket = if ($applicable -contains "webSocket") { "NOT_REVIEWED" } else { "NOT_APPLICABLE" }
                NoInfiniteSpinner = if ($isMandatory) { "NOT_REVIEWED" } else { "NOT_APPLICABLE" }
                Captcha = "NOT_CHECKED"
                AntiBot = "NOT_CHECKED"
                VpnProxyWarning = "NOT_CHECKED"
                ForeignRegionWarning = "NOT_CHECKED"
                RateLimiting = "NOT_CHECKED"
                RouteTelemetry = if ($requiresRouteTelemetry -and $currentPreset -ne "Direct") { "NOT_REVIEWED" } else { "NOT_APPLICABLE" }
                DnsTelemetry = if ($requiresRouteTelemetry -and $currentPreset -ne "Direct") { "NOT_REVIEWED" } else { "NOT_APPLICABLE" }
                MixedRouting = if ($requiresRouteTelemetry -and $currentPreset -eq "Russia") { "NOT_CHECKED" } else { "NOT_APPLICABLE" }
                PublicCountry = ""
                PublicASN = ""
                ASNCategory = ""
                PublicIPv4 = ""
                PublicIPv6 = ""
                DNSRegion = ""
                WebRTC = ""
                Timezone = ""
                Language = ""
                Notes = ""
            }
        }
    }
    return $rows
}

function Initialize-Stage28Session {
    $root = Resolve-OutputRoot
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    $sessionName = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ") + "-" + $DnsVariant.ToLowerInvariant()
    $newSession = Join-Path $root $sessionName
    if (Test-Path -LiteralPath $newSession) {
        throw "Session path already exists: $newSession"
    }
    [System.IO.Directory]::CreateDirectory($newSession) | Out-Null

    $scriptHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $gitCommit = (& git -C (Split-Path -Parent $PSScriptRoot) rev-parse HEAD 2>$null).Trim()
    $manifest = [ordered]@{
        schemaVersion = 1
        stage = "2.8"
        status = "EVIDENCE_NOT_COLLECTED"
        createdAtUtc = [DateTime]::UtcNow.ToString("o")
        dnsVariant = $DnsVariant
        dnsVariantIsEvidenceLabelOnly = $true
        runtimeDnsPolicyChangedByHarness = $false
        buildLabel = $BuildLabel
        gitCommit = $gitCommit
        harnessSha256 = $scriptHash
        preflight = $script:Preflight
        privacy = [ordered]@{
            ignoredLocalArtifact = $true
            chromeHistoryRead = $false
            cookiesRead = $false
            headersOrBodiesCaptured = $false
            logcatFilter = $script:TelemetryPrefix.Trim()
            note = "Screenshots and operator-entered public exit IPs are sensitive local evidence; do not commit or upload them."
        }
    }
    Write-JsonFile -Path (Join-Path $newSession "session.json") -Value $manifest
    Get-Stage28Sites | Export-Csv -LiteralPath (Join-Path $newSession "sites.csv") -NoTypeInformation -Encoding UTF8
    New-ObservationRows | Export-Csv -LiteralPath (Join-Path $newSession "operator-observations.csv") -NoTypeInformation -Encoding UTF8
    [System.IO.File]::WriteAllText(
        (Join-Path $newSession "SENSITIVE_LOCAL_EVIDENCE.txt"),
        "This ignored directory may contain screenshots and public exit IP evidence. Do not commit, publish, or attach it without an explicit privacy review.`r`n",
        $script:Utf8NoBom
    )
    Write-Host "Initialized Stage 2.8 browser evidence session:"
    Write-Host $newSession
    Write-Host "No site has been tested and no PASS has been assigned."
    return $newSession
}

function Resolve-Session {
    if (-not $SessionPath) {
        throw "-SessionPath is required for $Action."
    }
    $resolved = (Resolve-Path -LiteralPath $SessionPath).Path
    foreach ($required in @("session.json", "sites.csv", "operator-observations.csv")) {
        if (-not (Test-Path -LiteralPath (Join-Path $resolved $required))) {
            throw "Invalid Stage 2.8 session; missing $required in $resolved"
        }
    }
    return $resolved
}

function Assert-SessionMatchesPreflight {
    param([Parameter(Mandatory = $true)][string]$ResolvedSession)

    $manifest = Get-Content -LiteralPath (Join-Path $ResolvedSession "session.json") -Raw | ConvertFrom-Json
    $expectedModelValue = $manifest.preflight.device.model
    $expectedSerialHash = $manifest.preflight.device.serialSha256
    $expectedApkHash = $manifest.preflight.installedArtifact.apkSha256
    if ($script:Preflight.device.model -ne $expectedModelValue) {
        throw "Session device model differs from the connected device."
    }
    if ($script:Preflight.device.serialSha256 -ne $expectedSerialHash) {
        throw "Session belongs to a different physical device."
    }
    if ($script:Preflight.installedArtifact.apkSha256 -ne $expectedApkHash) {
        throw "Installed ZEON APK differs from the artifact pinned by this session."
    }
}

function Capture-AdbScreenshot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $script:AdbPath
    $processInfo.Arguments = "-s $($script:DeviceSerial) exec-out screencap -p"
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    $file = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    try {
        if (-not $process.Start()) {
            throw "Unable to start ADB screenshot capture."
        }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardOutput.BaseStream.CopyTo($file)
        $process.WaitForExit()
        $stderr = $stderrTask.Result
        if ($process.ExitCode -ne 0) {
            throw "ADB screenshot capture failed ($($process.ExitCode)): $stderr"
        }
    } finally {
        $file.Dispose()
        $process.Dispose()
    }
    if ((Get-Item -LiteralPath $Path).Length -lt 1024) {
        throw "Captured screenshot is unexpectedly small: $Path"
    }
}

function Get-TunStateEvidence {
    param([Parameter(Mandatory = $true)][string]$CurrentPreset)

    $tun = Invoke-DeviceAdb -Arguments @("shell", "ip", "link", "show", "tun0") -AllowFailure
    $present = $tun.ExitCode -eq 0 -and $tun.Text -match '\btun0\b'
    if ($CurrentPreset -eq "Direct" -and $present) {
        throw "tun0 is present in Direct mode. Disconnect ZEON and every other VPN before capture."
    }
    if ($CurrentPreset -ne "Direct" -and -not $present) {
        throw "tun0 is absent in $CurrentPreset mode. Connect ZEON before capture."
    }
    return [ordered]@{
        interface = "tun0"
        present = $present
        expected = $CurrentPreset -ne "Direct"
    }
}

function Get-DeviceEpoch {
    $epochResult = Invoke-DeviceAdb -Arguments @("shell", "date", "+%s")
    $epoch = 0L
    if (-not [long]::TryParse($epochResult.Text.Trim(), [ref]$epoch)) {
        throw "Unable to read a numeric device epoch for bounded logcat capture."
    }
    return $epoch
}

function Get-FocusedPackage {
    $windowDump = Invoke-DeviceAdb -Arguments @("shell", "dumpsys", "window", "windows")
    foreach ($line in $windowDump.Lines) {
        if ($line -match '(mCurrentFocus|mFocusedApp).*\s([A-Za-z0-9._]+)/(?:[A-Za-z0-9._$]+)') {
            return $Matches[2]
        }
    }
    return ""
}

function Convert-TelemetryLog {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$CurrentPreset,
        [Parameter(Mandatory = $true)]$Site,
        [Parameter(Mandatory = $true)][long]$AfterDeviceEpoch
    )

    $logcat = Invoke-DeviceAdb -Arguments @(
        "logcat", "-d", "-v", "epoch", "--regex=ZEON_ROUTE_VALIDATION"
    )
    $events = @()
    foreach ($line in $logcat.Lines) {
        if ($line -notmatch '^\s*(\d+(?:\.\d+)?)\s+') {
            continue
        }
        $deviceLogEpoch = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
        if ($deviceLogEpoch -lt [double]$AfterDeviceEpoch) {
            continue
        }
        $markerIndex = $line.IndexOf($script:TelemetryPrefix, [System.StringComparison]::Ordinal)
        if ($markerIndex -lt 0) {
            continue
        }
        $payload = $line.Substring($markerIndex + $script:TelemetryPrefix.Length).Trim()
        try {
            $event = $payload | ConvertFrom-Json
        } catch {
            throw "Malformed validation telemetry JSON: $payload"
        }
        foreach ($field in $script:RequiredTelemetryFields) {
            if ($null -eq $event.PSObject.Properties[$field]) {
                throw "Validation telemetry is missing required field '$field': $payload"
            }
        }
        if (-not $event.hostname) {
            throw "Validation telemetry has no hostname correlation: $payload"
        }
        if ($event.resolvedIpHash -and $event.resolvedIpHash -notmatch '^hmac-sha256:[0-9a-f]{32}$') {
            throw "Validation telemetry contains an unsafe resolved IP representation."
        }
        if (-not $event.generation) {
            throw "Validation telemetry has an empty session generation."
        }
        if ($event.kind -notin @("route", "dns")) {
            throw "Validation telemetry has an unsupported event kind '$($event.kind)': $payload"
        }
        if ($event.kind -eq "route") {
            if (-not $event.resolvedIpHash) {
                throw "Route telemetry has no resolved IP hash: $payload"
            }
            if ($event.ipVersion -notin @("IPv4", "IPv6")) {
                throw "Route telemetry has no IPv4/IPv6 classification: $payload"
            }
            if ($event.route -notin @("DIRECT", "VPN", "BLOCK")) {
                throw "Route telemetry has an invalid route outcome: $payload"
            }
            if ($event.dns -notin @("DIRECT", "REMOTE", "BLOCK")) {
                throw "Route telemetry is not correlated with an exact DNS decision: $payload"
            }
        }
        $record = [ordered]@{
            capturedAtUtc = [DateTime]::UtcNow.ToString("o")
            deviceLogEpoch = $deviceLogEpoch
            preset = $CurrentPreset
            siteId = $Site.Id
            event = $event
        }
        $events += $record
    }

    $generations = @($events |
        ForEach-Object { [string]$_.event.generation } |
        Where-Object { $_ } |
        Select-Object -Unique)
    if ($generations.Count -gt 1) {
        throw "Capture mixes multiple ZEON session generations ($($generations -join ', ')); reconnect/stale evidence is rejected."
    }

    $lines = @($events | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress })
    [System.IO.File]::WriteAllLines($Path, [string[]]$lines, $script:Utf8NoBom)
    return $events
}

function Get-AutomatedRouteAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$CurrentPreset,
        [Parameter(Mandatory = $true)]$Site,
        [Parameter(Mandatory = $true)][array]$Events,
        [Parameter(Mandatory = $true)]
        [ValidateSet("DIRECT_DNS", "REMOTE_DNS_BASELINE")]
        [string]$ExpectedDnsVariant
    )

    $routeEvents = @($Events | Where-Object { $_.event.kind -eq "route" })
    $dnsEvents = @($Events | Where-Object { $_.event.kind -eq "dns" })
    $isSuffixRoute = @($Site.Applicable -split ';') -contains "suffixRoute"
    $requiresRouteEvidence = ($Site.Kind -eq "mandatory") -or $isSuffixRoute
    $hostnameCorrelatedRoutes = @($routeEvents | Where-Object {
        $_.event.hostname -and
        $_.event.resolvedIpHash -and
        $_.event.ipVersion -in @("IPv4", "IPv6") -and
        $_.event.dns -in @("DIRECT", "REMOTE", "BLOCK")
    })
    $siteHost = ([System.Uri]$Site.Url).DnsSafeHost.TrimEnd(".").ToLowerInvariant()
    $rootHostRoutes = @($hostnameCorrelatedRoutes | Where-Object {
        $_.event.hostname.TrimEnd(".").ToLowerInvariant() -eq $siteHost
    })
    $hostnameCorrelatedDns = @($dnsEvents | Where-Object {
        $_.event.hostname -and
        $_.event.resolvedIpHash -and
        $_.event.ipVersion -in @("IPv4", "IPv6") -and
        $_.event.dns -in @("DIRECT", "REMOTE", "BLOCK")
    })
    $rootHostDns = @($hostnameCorrelatedDns | Where-Object {
        $_.event.hostname.TrimEnd(".").ToLowerInvariant() -eq $siteHost
    })
    $generations = @($Events |
        ForEach-Object { [string]$_.event.generation } |
        Where-Object { $_ } |
        Select-Object -Unique)
    if ($generations.Count -gt 1) {
        throw "Assessment received mixed ZEON session generations ($($generations -join ', '))."
    }
    $captureGeneration = if ($generations.Count -eq 1) { $generations[0] } else { "" }
    $result = "NOT_APPLICABLE"
    $mixed = $false
    $reason = ""

    if ($requiresRouteEvidence) {
        if ($CurrentPreset -eq "Direct") {
            if ($Events.Count -ne 0) {
                $result = "UNEXPECTED_ZEON_TELEMETRY"
                $reason = "ZEON telemetry was emitted while the operator attested Direct/off."
            } else {
                $result = "DIRECT_BASELINE_RECORDED"
            }
        } elseif ($hostnameCorrelatedRoutes.Count -eq 0 -or $hostnameCorrelatedDns.Count -eq 0) {
            $result = "MISSING_HOSTNAME_CORRELATED_TELEMETRY"
            $reason = "A mandatory/suffix site requires separate route and kind=dns evidence correlated to hostname, resolved IP hash, IP family and DNS decision."
        } elseif ($rootHostDns.Count -eq 0) {
            $result = "MISSING_HOSTNAME_CORRELATED_TELEMETRY"
            $reason = "No separate kind=dns event with resolved IP evidence was captured for browser entry hostname '$siteHost'."
        } elseif ($rootHostRoutes.Count -eq 0) {
            $result = "MISSING_ROOT_HOST_TELEMETRY"
            $reason = "No hostname-correlated route event was captured for the browser entry hostname '$siteHost'."
        } elseif ($CurrentPreset -eq "Russia" -and $isSuffixRoute -and @($rootHostRoutes | Where-Object {
            @($_.event.matchedRuleSet -split ',') -contains "zapret-ru-domains"
        }).Count -eq 0) {
            $result = "SUFFIX_RULE_SET_FAILURE"
            $reason = "The suffix acceptance target did not match the bundled zapret-ru-domains rule set."
        } else {
            $expectedRoute = if ($CurrentPreset -eq "Russia") { "DIRECT" } else { "VPN" }
            $unexpectedRoute = @($hostnameCorrelatedRoutes | Where-Object { $_.event.route -ne $expectedRoute })
            $uniqueRoutes = @($hostnameCorrelatedRoutes | ForEach-Object { $_.event.route } | Select-Object -Unique)
            $mixed = $uniqueRoutes.Count -gt 1
            if ($CurrentPreset -eq "Russia") {
                $expectedDns = if ($ExpectedDnsVariant -eq "DIRECT_DNS") { "DIRECT" } else { "REMOTE" }
                $unexpectedDns = @($hostnameCorrelatedRoutes | Where-Object { $_.event.dns -ne $expectedDns })
                $unexpectedDns += @($dnsEvents | Where-Object { $_.event.dns -ne $expectedDns })
                if ($mixed -or $unexpectedRoute.Count -gt 0) {
                    $result = "MIXED_ROUTING_FAILURE"
                    $reason = "At least one allowlisted resource did not route DIRECT in Russia mode."
                } elseif ($unexpectedDns.Count -gt 0) {
                    $result = "DNS_ROUTING_FAILURE"
                    $reason = "At least one allowlisted resource did not use expected DNS '$expectedDns' for evidence variant '$ExpectedDnsVariant'."
                } else {
                    $result = "EXPECTED_ROUTE_OBSERVED"
                }
            } elseif ($mixed -or $unexpectedRoute.Count -gt 0) {
                $result = "GLOBAL_ROUTING_FAILURE"
                $reason = "At least one allowlisted resource did not route through VPN in Global mode."
            } elseif (@($hostnameCorrelatedRoutes | Where-Object { $_.event.dns -ne "REMOTE" }).Count -gt 0) {
                $result = "GLOBAL_DNS_FAILURE"
                $reason = "At least one hostname-correlated Global resource did not use remote DNS."
            } else {
                $result = "EXPECTED_ROUTE_OBSERVED"
            }
        }
    }

    return [ordered]@{
        assessedAtUtc = [DateTime]::UtcNow.ToString("o")
        preset = $CurrentPreset
        siteId = $Site.Id
        eventCount = $Events.Count
        routeEventCount = $routeEvents.Count
        dnsEventCount = $dnsEvents.Count
        hostnameCorrelatedRouteCount = $hostnameCorrelatedRoutes.Count
        hostnameCorrelatedDnsCount = $hostnameCorrelatedDns.Count
        browserEntryHostname = $siteHost
        browserEntryHostnameObserved = $rootHostRoutes.Count -gt 0
        browserEntryHostnameDnsObserved = $rootHostDns.Count -gt 0
        generation = $captureGeneration
        expectedDnsVariant = $ExpectedDnsVariant
        result = $result
        mixedRouting = $mixed
        reason = $reason
        caveat = "This is route evidence only. It is not a browser PASS and cannot prove that every mandatory resource was exercised."
    }
}

function Invoke-PresetRun {
    param([Parameter(Mandatory = $true)][string]$ResolvedSession)

    if (-not $Preset) {
        throw "-Preset is required for RunPreset."
    }
    Assert-SessionMatchesPreflight -ResolvedSession $ResolvedSession
    $sessionManifest = Get-Content -LiteralPath (Join-Path $ResolvedSession "session.json") -Raw | ConvertFrom-Json
    $expectedDnsVariant = [string]$sessionManifest.dnsVariant
    if ($expectedDnsVariant -notin @("DIRECT_DNS", "REMOTE_DNS_BASELINE")) {
        throw "Session contains unsupported DNS evidence label '$expectedDnsVariant'."
    }

    $presetDirectory = Join-Path $ResolvedSession $Preset.ToLowerInvariant()

    Write-Host ""
    switch ($Preset) {
        "Direct" {
            Write-Host "Operator gate: disconnect ZEON and every other VPN. Confirm the device uses its ordinary Russian physical connection."
        }
        "Russia" {
            Write-Host "Operator gate: select ZEON Russia, connect, and wait for Connected. Per-app bypass must be OFF."
        }
        "Global" {
            Write-Host "Operator gate: select ZEON Global, connect, and wait for Connected. Per-app bypass must be OFF."
        }
    }
    $attestation = Read-Host "Type exactly READY after checking the preset on the OnePlus"
    if ($attestation -cne "READY") {
        throw "Preset was not attested. No browser evidence was collected."
    }
    $tunEvidence = Get-TunStateEvidence -CurrentPreset $Preset
    [System.IO.Directory]::CreateDirectory($presetDirectory) | Out-Null
    $attestationName = "attestation-" + [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ") + ".json"
    Write-JsonFile -Path (Join-Path $presetDirectory $attestationName) -Value ([ordered]@{
        attestedAtUtc = [DateTime]::UtcNow.ToString("o")
        preset = $Preset
        operatorTypedReady = $true
        tun = $tunEvidence
        limitation = "The TUN state is machine-checked; Russia versus Global selection remains an explicit operator attestation."
    })

    $sites = Get-Stage28Sites
    foreach ($site in $sites) {
        $siteDirectory = Join-Path $presetDirectory $site.Id
        if (Test-Path -LiteralPath (Join-Path $siteDirectory "capture.json")) {
            Write-Host "[$Preset] $($site.Name) already has immutable capture evidence; skipping."
            continue
        }
        if (Test-Path -LiteralPath $siteDirectory) {
            throw "Partial evidence directory requires manual review and was not overwritten: $siteDirectory"
        }

        Write-Host ""
        Write-Host "[$Preset] $($site.Name) - $($site.Url)"
        $continue = Read-Host "OPEN to launch in Chrome, SKIP to leave a gap, or QUIT"
        if ($continue -ceq "QUIT") {
            break
        }
        if ($continue -ceq "SKIP") {
            continue
        }
        if ($continue -cne "OPEN") {
            throw "Unexpected operator response. No evidence was recorded for $($site.Id)."
        }

        $logcatAfterEpoch = Get-DeviceEpoch
        Invoke-DeviceAdb -Arguments @("shell", "am", "force-stop", $BrowserPackage) | Out-Null
        $launch = Invoke-DeviceAdb -Arguments @(
            "shell", "am", "start", "-W",
            "-a", "android.intent.action.VIEW",
            "-d", $site.Url,
            "-p", $BrowserPackage
        )
        if ($launch.Text -notmatch '(?m)^Status:\s+ok\s*$') {
            throw "Chrome did not report a successful browser launch for $($site.Id):`n$($launch.Text)"
        }
        if ($SettleSeconds -gt 0) {
            Start-Sleep -Seconds $SettleSeconds
        }
        Write-Host "Inspect visual load, JS/CSS/images, APIs/CDNs, redirects and all applicable interactions."
        $capture = Read-Host "Type CAPTURE when the inspected page is visible in Chrome"
        if ($capture -cne "CAPTURE") {
            throw "Capture was not confirmed for $($site.Id)."
        }
        $focusedPackage = Get-FocusedPackage
        if ($focusedPackage -ne $BrowserPackage) {
            throw "Expected Chrome in foreground, got '$focusedPackage'. Return to Chrome and rerun this preset."
        }

        [System.IO.Directory]::CreateDirectory($siteDirectory) | Out-Null
        $screenshotPath = Join-Path $siteDirectory "browser.png"
        Capture-AdbScreenshot -Path $screenshotPath
        $telemetryPath = Join-Path $siteDirectory "telemetry.jsonl"
        $events = @(Convert-TelemetryLog `
            -Path $telemetryPath `
            -CurrentPreset $Preset `
            -Site $site `
            -AfterDeviceEpoch $logcatAfterEpoch)
        $assessment = Get-AutomatedRouteAssessment `
            -CurrentPreset $Preset `
            -Site $site `
            -Events $events `
            -ExpectedDnsVariant $expectedDnsVariant
        Write-JsonFile -Path (Join-Path $siteDirectory "route-assessment.json") -Value $assessment
        Write-JsonFile -Path (Join-Path $siteDirectory "capture.json") -Value ([ordered]@{
            capturedAtUtc = [DateTime]::UtcNow.ToString("o")
            preset = $Preset
            siteId = $site.Id
            name = $site.Name
            url = $site.Url
            browserPackage = $BrowserPackage
            foregroundPackage = $focusedPackage
            logcatAfterDeviceEpoch = $logcatAfterEpoch
            expectedDnsVariant = $expectedDnsVariant
            generation = $assessment.generation
            screenshotSha256 = (Get-FileHash -LiteralPath $screenshotPath -Algorithm SHA256).Hash.ToLowerInvariant()
            telemetrySha256 = (Get-FileHash -LiteralPath $telemetryPath -Algorithm SHA256).Hash.ToLowerInvariant()
            automatedRouteResult = $assessment.result
        })
        Write-Host "Captured $($site.Id): route evidence $($assessment.result). This is not a browser PASS."
    }

    Write-Host ""
    Write-Host "Preset capture ended. Complete operator-observations.csv before Finalize."
}

function Assert-AllowedValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string]$Context
    )
    if ($Allowed -notcontains $Value) {
        throw "$Context has invalid $Name '$Value'. Allowed: $($Allowed -join ', ')"
    }
}

function Finalize-Stage28Session {
    param([Parameter(Mandatory = $true)][string]$ResolvedSession)

    $sites = Get-Stage28Sites
    $rows = @(Import-Csv -LiteralPath (Join-Path $ResolvedSession "operator-observations.csv"))
    $expectedRowCount = $sites.Count * 3
    if ($rows.Count -ne $expectedRowCount) {
        throw "Observation matrix has $($rows.Count) rows; expected $expectedRowCount."
    }

    $failures = New-Object System.Collections.Generic.List[string]
    $evidence = New-Object System.Collections.Generic.List[object]
    foreach ($currentPreset in @("Direct", "Russia", "Global")) {
        $presetDirectory = Join-Path $ResolvedSession $currentPreset.ToLowerInvariant()
        $attestations = @()
        if (Test-Path -LiteralPath $presetDirectory) {
            $attestations = @(Get-ChildItem -LiteralPath $presetDirectory -Filter "attestation-*.json" -File)
        }
        if ($attestations.Count -eq 0) {
            $failures.Add("${currentPreset}: missing preset attestation and TUN evidence.")
        } else {
            $latestAttestationPath = ($attestations |
                Sort-Object LastWriteTimeUtc |
                Select-Object -Last 1).FullName
            $latestAttestation = Get-Content -LiteralPath $latestAttestationPath -Raw | ConvertFrom-Json
            $expectedTun = $currentPreset -ne "Direct"
            if ($latestAttestation.preset -ne $currentPreset -or $latestAttestation.tun.present -ne $expectedTun) {
                $failures.Add("${currentPreset}: latest preset attestation has inconsistent TUN evidence.")
            }
        }
        foreach ($site in $sites) {
            $matchingRows = @($rows | Where-Object {
                $_.Preset -eq $currentPreset -and $_.SiteId -eq $site.Id
            })
            if ($matchingRows.Count -ne 1) {
                $failures.Add("$currentPreset/$($site.Id): observation row is missing or duplicated.")
                continue
            }
            $row = $matchingRows[0]
            $siteDirectory = Join-Path $presetDirectory $site.Id
            foreach ($fileName in @("browser.png", "telemetry.jsonl", "route-assessment.json", "capture.json")) {
                if (-not (Test-Path -LiteralPath (Join-Path $siteDirectory $fileName))) {
                    $failures.Add("$currentPreset/$($site.Id): missing $fileName.")
                }
            }

            if ($site.Kind -eq "mandatory") {
                $applicable = @($site.Applicable -split ';')
                if ($row.Status -ne "PASS") {
                    $failures.Add("$currentPreset/$($site.Id): operator Status is '$($row.Status)', not PASS.")
                }
                $functionalFields = [ordered]@{
                    VisualLoad = "visual"
                    JavaScript = "js"
                    CSS = "css"
                    Images = "images"
                    API = "api"
                    CDN = "cdn"
                    Redirects = "redirects"
                    Search = "search"
                    PublicCards = "publicCards"
                    VideoPreviewPlayback = "video"
                    WebSocket = "webSocket"
                    NoInfiniteSpinner = "visual"
                }
                foreach ($field in $functionalFields.Keys) {
                    $required = $applicable -contains $functionalFields[$field]
                    try {
                        Assert-AllowedValue `
                            -Name $field `
                            -Value $row.$field `
                            -Allowed $(if ($required) { @("PASS") } else { @("PASS", "NOT_APPLICABLE") }) `
                            -Context "$currentPreset/$($site.Id)"
                    } catch {
                        $failures.Add($_.Exception.Message)
                    }
                }
                foreach ($field in @("Captcha", "AntiBot", "VpnProxyWarning", "ForeignRegionWarning", "RateLimiting")) {
                    try {
                        Assert-AllowedValue `
                            -Name $field `
                            -Value $row.$field `
                            -Allowed @("NONE", "PRESENT_EXPLAINED") `
                            -Context "$currentPreset/$($site.Id)"
                    } catch {
                        $failures.Add($_.Exception.Message)
                    }
                    if ($row.$field -eq "PRESENT_EXPLAINED" -and -not $row.Notes.Trim()) {
                        $failures.Add("$currentPreset/$($site.Id): $field is PRESENT_EXPLAINED but Notes is empty.")
                    }
                }
                if ($currentPreset -eq "Direct") {
                    if ($row.RouteTelemetry -ne "NOT_APPLICABLE" -or $row.DnsTelemetry -ne "NOT_APPLICABLE") {
                        $failures.Add("$currentPreset/$($site.Id): ZEON telemetry must be NOT_APPLICABLE while ZEON is off.")
                    }
                } else {
                    if ($row.RouteTelemetry -ne "PASS" -or $row.DnsTelemetry -ne "PASS") {
                        $failures.Add("$currentPreset/$($site.Id): operator did not confirm route and DNS telemetry.")
                    }
                }
                if ($currentPreset -eq "Russia" -and $row.MixedRouting -ne "NONE") {
                    $failures.Add("$currentPreset/$($site.Id): MixedRouting is '$($row.MixedRouting)', expected NONE.")
                }
            } else {
                if ($row.Status -ne "RECORDED") {
                    $failures.Add("$currentPreset/$($site.Id): diagnostic Status is '$($row.Status)', expected RECORDED.")
                }
                $applicable = @($site.Applicable -split ';')
                if ($applicable -contains "suffixRoute") {
                    if ($currentPreset -eq "Direct") {
                        if ($row.RouteTelemetry -ne "NOT_APPLICABLE" -or $row.DnsTelemetry -ne "NOT_APPLICABLE") {
                            $failures.Add("$currentPreset/$($site.Id): ZEON telemetry must be NOT_APPLICABLE while ZEON is off.")
                        }
                    } elseif ($row.RouteTelemetry -ne "PASS" -or $row.DnsTelemetry -ne "PASS") {
                        $failures.Add("$currentPreset/$($site.Id): suffix routing diagnostic lacks confirmed route/DNS telemetry.")
                    }
                    if ($currentPreset -eq "Russia" -and $row.MixedRouting -ne "NONE") {
                        $failures.Add("$currentPreset/$($site.Id): suffix routing diagnostic has MixedRouting '$($row.MixedRouting)'.")
                    }
                }
                $diagnosticFields = [ordered]@{
                    country = "PublicCountry"
                    asn = "PublicASN"
                    ipv4 = "PublicIPv4"
                    ipv6 = "PublicIPv6"
                    dnsRegion = "DNSRegion"
                    webrtc = "WebRTC"
                    timezone = "Timezone"
                    language = "Language"
                }
                foreach ($token in $diagnosticFields.Keys) {
                    $field = $diagnosticFields[$token]
                    if ($applicable -contains $token -and -not $row.$field.Trim()) {
                        $failures.Add("$currentPreset/$($site.Id): diagnostic field $field is empty.")
                    }
                }
                if ($applicable -contains "asnCategory") {
                    try {
                        Assert-AllowedValue `
                            -Name "ASNCategory" `
                            -Value $row.ASNCategory `
                            -Allowed @("residential", "mobile", "hosting", "datacenter", "unknown") `
                            -Context "$currentPreset/$($site.Id)"
                    } catch {
                        $failures.Add($_.Exception.Message)
                    }
                }
                if ($applicable -contains "vpnWarnings") {
                    foreach ($field in @("VpnProxyWarning", "ForeignRegionWarning")) {
                        try {
                            Assert-AllowedValue `
                                -Name $field `
                                -Value $row.$field `
                                -Allowed @("NONE", "PRESENT_EXPLAINED") `
                                -Context "$currentPreset/$($site.Id)"
                        } catch {
                            $failures.Add($_.Exception.Message)
                        }
                    }
                }
                if ($applicable -contains "captcha") {
                    try {
                        Assert-AllowedValue `
                            -Name "Captcha" `
                            -Value $row.Captcha `
                            -Allowed @("NONE", "PRESENT_EXPLAINED") `
                            -Context "$currentPreset/$($site.Id)"
                    } catch {
                        $failures.Add($_.Exception.Message)
                    }
                }
                if ($applicable -contains "rateLimit") {
                    try {
                        Assert-AllowedValue `
                            -Name "RateLimiting" `
                            -Value $row.RateLimiting `
                            -Allowed @("NONE", "PRESENT_EXPLAINED") `
                            -Context "$currentPreset/$($site.Id)"
                    } catch {
                        $failures.Add($_.Exception.Message)
                    }
                }
                if ($site.Id -eq "ru_public_exit" -and $currentPreset -in @("Direct", "Russia")) {
                    if ($row.PublicCountry.Trim().ToUpperInvariant() -ne "RU") {
                        $failures.Add("$currentPreset/$($site.Id): PublicCountry must be ISO code RU for the ordinary Russian exit.")
                    }
                    if ($row.ASNCategory -notin @("residential", "mobile")) {
                        $failures.Add("$currentPreset/$($site.Id): ASNCategory '$($row.ASNCategory)' does not prove an ordinary residential/mobile Russian exit.")
                    }
                }
            }

            $assessmentPath = Join-Path $siteDirectory "route-assessment.json"
            if (Test-Path -LiteralPath $assessmentPath) {
                $assessment = Get-Content -LiteralPath $assessmentPath -Raw | ConvertFrom-Json
                $requiresRouteAssessment = $site.Kind -eq "mandatory" -or @($site.Applicable -split ';') -contains "suffixRoute"
                $expectedAssessment = if (-not $requiresRouteAssessment) {
                    "NOT_APPLICABLE"
                } elseif ($currentPreset -eq "Direct") {
                    "DIRECT_BASELINE_RECORDED"
                } else {
                    "EXPECTED_ROUTE_OBSERVED"
                }
                if ($assessment.result -ne $expectedAssessment) {
                    $failures.Add("$currentPreset/$($site.Id): automated route result is '$($assessment.result)'.")
                }
            }

            if (Test-Path -LiteralPath $siteDirectory) {
                $evidence.Add([ordered]@{
                    preset = $currentPreset
                    siteId = $site.Id
                    kind = $site.Kind
                    directory = $currentPreset.ToLowerInvariant() + "/" + $site.Id
                })
            }
        }
    }

    $manifest = Get-Content -LiteralPath (Join-Path $ResolvedSession "session.json") -Raw | ConvertFrom-Json
    $result = [ordered]@{
        finalizedAtUtc = [DateTime]::UtcNow.ToString("o")
        status = if ($failures.Count -eq 0) { "OPERATOR_EVIDENCE_COMPLETE" } else { "INCOMPLETE_OR_FAILED" }
        stagePassAssigned = $false
        dnsVariant = $manifest.dnsVariant
        failureCount = $failures.Count
        failures = @($failures)
        evidence = @($evidence)
        statement = "This harness never assigns Stage 2.8 PASS. Engineering review must compare Direct/Russia/Global, the DIRECT_DNS run, the REMOTE_DNS_BASELINE run, screenshots, operator observations, and route telemetry."
    }
    Write-JsonFile -Path (Join-Path $ResolvedSession "finalization.json") -Value $result -Depth 20

    if ($failures.Count -gt 0) {
        Write-Host "Evidence is incomplete or failed ($($failures.Count) findings)."
        foreach ($failure in $failures) {
            Write-Host " - $failure"
        }
        exit 2
    }
    Write-Host "Operator evidence is complete. Stage 2.8 PASS has NOT been assigned."
}

$script:AdbPath = Resolve-Adb
$script:DeviceSerial = ""
$script:Preflight = $null

switch ($Action) {
    "Preflight" {
        $preflight = Invoke-Stage28Preflight
        Write-Host "PREFLIGHT OK: $($preflight.device.manufacturer) $($preflight.device.model), Android $($preflight.device.androidRelease), Chrome $($preflight.browser.versionName)."
        Write-Host "Validation APK SHA-256: $($preflight.installedArtifact.apkSha256)"
        Write-Host "No browser test was executed."
    }
    "Initialize" {
        Invoke-Stage28Preflight | Out-Null
        Initialize-Stage28Session | Out-Null
    }
    "RunPreset" {
        Invoke-Stage28Preflight | Out-Null
        $resolvedSession = Resolve-Session
        Invoke-PresetRun -ResolvedSession $resolvedSession
    }
    "Finalize" {
        $resolvedSession = Resolve-Session
        Finalize-Stage28Session -ResolvedSession $resolvedSession
    }
}
