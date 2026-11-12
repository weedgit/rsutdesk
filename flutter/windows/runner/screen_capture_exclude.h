#pragma once

#include <windows.h>

// Hides RustDesk windows from screen capture, screen sharing, and DXGI duplication
// (OBS, Teams, etc.). Requires Windows 10 version 2004 (build 19041) or later.
bool RustDeskExcludeWindowFromScreenCapture(HWND hwnd);
