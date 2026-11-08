# Builds dist\rustdesk-team-<version>-install.exe: one file that installs RustDesk Team.
# team\allowed-ips.txt is built into the app (a fresh install starts with that list), so edit it
# before building. Run from anywhere on the Windows build PC. -SkipBuild packs the current
# Release folder as is (only when nothing in the Rust core or the app changed since).
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
$version = (Select-String -Path Cargo.toml -Pattern '^version = "(.+)"' | Select-Object -First 1).Matches[0].Groups[1].Value
New-Item -ItemType Directory (Join-Path $root 'dist') -Force | Out-Null
# The name must end in "install.exe": double-clicking such a file opens RustDesk's install screen.
$out = Join-Path $root "dist\rustdesk-team-$version-install.exe"
Copy-Item target\release\rustdesk-portable-packer.exe $out -Force -ErrorAction Stop
Write-Host "Built $out"
