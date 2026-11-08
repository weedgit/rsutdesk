# RustDesk Team installer for Windows: silent install as a service, then the allowed IP list.
$ErrorActionPreference = 'Stop'
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
function Done($msg) { Write-Host ""; Write-Host $msg; Read-Host "Press Enter to close" | Out-Null; exit }
try {
    $here = Split-Path -Parent $PSCommandPath
    $ips = (Get-Content (Join-Path $here 'allowed-ips.txt') |
        ForEach-Object { ($_ -split '#')[0] -split '[,\s]+' } | Where-Object { $_ }) -join ','
    if (-not $ips) { throw 'allowed-ips.txt lists no IP address.' }

    Write-Host 'Installing RustDesk Team...'
    Start-Process (Join-Path $here 'rustdesk-team-setup.exe') -ArgumentList '--silent-install' -Wait
    $exe = Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'
    for ($i = 0; $i -lt 120; $i++) {
        $svc = Get-Service RustDesk -ErrorAction SilentlyContinue
        if ((Test-Path $exe) -and $svc -and $svc.Status -eq 'Running') { break }
        Start-Sleep 1
    }
    if (-not (Test-Path $exe)) { throw 'RustDesk did not install.' }
    Start-Sleep 3   # let the service open its settings channel

    Write-Host "Allowing: $ips"
    & $exe --option whitelist $ips | Out-Null
    $got = (& $exe --option whitelist | Out-String).Trim()
    if ($got -ne $ips) { throw "The allowed IP list did not stick (it reads '$got')." }
    Done "Done. RustDesk runs as a service and starts with Windows. Allowed: $got"
} catch {
    Done "Installation failed: $($_.Exception.Message)"
}
