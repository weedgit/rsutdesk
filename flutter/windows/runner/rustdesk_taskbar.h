#pragma once

#include <windows.h>

// Full stealth for the main window (includes owner reparenting).
void RustDeskHideWindowFromTaskbar(HWND hwnd);

// Sub-windows: shell stealth + WDA_EXCLUDEFROMCAPTURE after first frame.
void RustDeskApplyShellStealth(HWND hwnd);
