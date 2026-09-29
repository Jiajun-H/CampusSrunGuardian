$ErrorActionPreference = 'SilentlyContinue'

$ssidPath = Join-Path $env:ProgramData 'CampusSrunGuardian\campus-ssid.txt'
$executable = Join-Path $PSScriptRoot 'CampusSrunGuardian.exe'
if (-not (Test-Path -LiteralPath $ssidPath) -or -not (Test-Path -LiteralPath $executable)) {
    exit 0
}

$ssidConfig = [IO.File]::ReadAllText($ssidPath).Trim([char]0xFEFF, [char]0x000D, [char]0x000A, [char]0x0020)
if ([String]::IsNullOrWhiteSpace($ssidConfig)) {
    exit 0
}
try {
    $decodedSsid = ConvertFrom-Json -InputObject $ssidConfig -ErrorAction Stop
    $allowedSsids = @($decodedSsid | ForEach-Object { [String]$_ })
} catch {
    $allowedSsids = @($ssidConfig)
}

$wlanOutput = (& netsh.exe wlan show interfaces 2>$null | Out-String)
$campusWifiConnected = $false
foreach ($ssidMatch in [regex]::Matches($wlanOutput, '(?im)^\s*SSID\s*:\s*(?<ssid>[^\r\n]+?)\s*$')) {
    $ssid = $ssidMatch.Groups['ssid'].Value.Trim()
    $hasCampusPrefix = $ssid.StartsWith('zuel', [StringComparison]::OrdinalIgnoreCase)
    $isCapturedCampusSsid = $allowedSsids | Where-Object {
        [String]::Equals($ssid, $_, [StringComparison]::OrdinalIgnoreCase)
    }
    if ($hasCampusPrefix -or $isCapturedCampusSsid) {
        $campusWifiConnected = $true
        break
    }
}

if (-not $campusWifiConnected) {
    exit 0
}

& $executable --once
exit $LASTEXITCODE
