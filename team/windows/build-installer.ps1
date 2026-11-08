# Builds dist\RustDesk-Team-Windows: the packed setup plus install.cmd/install.ps1 and allowed-ips.txt.
# Run from anywhere on the Windows build PC. -SkipBuild packs the current Release folder as is.
param([switch]$SkipBuild)
# Not 'Stop': Windows PowerShell 5.1 would treat cargo's warnings on stderr as fatal. Native
# steps are checked by exit code; the file steps pass -ErrorAction Stop themselves.
$ErrorActionPreference = 'Continue'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$release = Join-Path $root 'flutter\build\windows\x64\runner\Release'
Set-Location $root
if (-not $SkipBuild) {
    cargo build --locked --features flutter --lib --release
    if ($LASTEXITCODE) { throw 'cargo build failed' }
    Push-Location flutter; flutter build windows --release; $rc = $LASTEXITCODE; Pop-Location
    if ($rc) { throw 'flutter build failed' }
    Copy-Item target\release\librustdesk.dll $release -Force -ErrorAction Stop
}
Copy-Item target\release\deps\dylib_virtual_display.dll $release -Force -ErrorAction Stop
python -m pip install --quiet -r libs\portable\requirements.txt
Push-Location libs\portable
python generate.py -f $release -o . -e (Join-Path $release 'rustdesk.exe')
$rc = $LASTEXITCODE; Pop-Location
if ($rc) { throw 'packing failed' }
$out = Join-Path $root 'dist\RustDesk-Team-Windows'
Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $out | Out-Null
Copy-Item target\release\rustdesk-portable-packer.exe (Join-Path $out 'rustdesk-team-setup.exe') -ErrorAction Stop
Copy-Item team\windows\install.cmd, team\windows\install.ps1, team\allowed-ips.txt $out -ErrorAction Stop
Write-Host "Built $out"
