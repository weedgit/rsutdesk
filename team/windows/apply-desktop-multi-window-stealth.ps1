# Re-applies RustDesk team patch to rustdesk_desktop_multi_window in Pub cache.
# Run after `flutter pub get` if the cache checkout was re-fetched.

$ErrorActionPreference = "Stop"
$ref = "cddc2e64f8fefce4f80db87b20bcda2dd019bed6"
$cacheRoot = Join-Path $env:LOCALAPPDATA "Pub\Cache\git"
$repoDir = Get-ChildItem -Path $cacheRoot -Directory -Filter "rustdesk_desktop_multi_window-$ref" |
  Select-Object -First 1 -ExpandProperty FullName
if (-not $repoDir) {
  throw "desktop_multi_window git cache not found. Run flutter pub get first."
}

$patchDir = Join-Path $PSScriptRoot "desktop_multi_window_stealth"
Copy-Item (Join-Path $patchDir "desktop_multi_window_plugin.h") `
  (Join-Path $repoDir "windows\include\desktop_multi_window\desktop_multi_window_plugin.h") -Force

$flutterWindow = Join-Path $repoDir "windows\flutter_window.cc"
$content = Get-Content $flutterWindow -Raw
if ($content -notmatch "_g_subwindow_first_presented_callback") {
  $content = $content -replace `
    "WindowCreatedCallback _g_window_created_callback = nullptr;",
    @"
WindowCreatedCallback _g_window_created_callback = nullptr;
SubWindowFirstPresentedCallback _g_subwindow_first_presented_callback =
    nullptr;
"@
  $content = $content -replace `
    "          ForceChildRefresh\(\);\r?\n          KillTimer\(hwnd, kForceRedrawTimerId\);",
    @"
          ForceChildRefresh();
          KillTimer(hwnd, kForceRedrawTimerId);
          if (_g_subwindow_first_presented_callback && window_handle_) {
            _g_subwindow_first_presented_callback(window_handle_);
          }
"@
  $content = $content -replace `
    "void DesktopMultiWindowSetWindowCreatedCallback\(WindowCreatedCallback callback\) \{\r?\n  _g_window_created_callback = callback;\r?\n\}",
    @"
void DesktopMultiWindowSetWindowCreatedCallback(WindowCreatedCallback callback) {
  _g_window_created_callback = callback;
}

void DesktopMultiWindowSetSubWindowFirstPresentedCallback(
    SubWindowFirstPresentedCallback callback) {
  _g_subwindow_first_presented_callback = callback;
}
"@
  Set-Content -Path $flutterWindow -Value $content -NoNewline
}

Write-Host "Patched: $repoDir"
