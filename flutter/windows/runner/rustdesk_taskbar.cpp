#include "rustdesk_taskbar.h"

#include "screen_capture_exclude.h"

#include <dwmapi.h>
#include <propsys.h>
#include <propkey.h>
#include <shobjidl.h>

#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "propsys.lib")

namespace {

#ifndef DWMFLIP3D_EXCLUDEBELOW
#define DWMFLIP3D_EXCLUDEBELOW 1
#endif

// Not declared in all Windows SDK propkey.h versions used by Flutter/VS toolchains.
constexpr PROPERTYKEY kPkeyAppUserModelIsSystemComponent{
    {0x9f4c2855, 0x9f79, 0x4b39, {0xa8, 0xd0, 0xe1, 0x42, 0xd2, 0xb3, 0x43, 0xb5}},
    5,
};

// Unowned top-level windows are forced into the taskbar, Alt+Tab and Win+Tab when shown.
HWND StealthOwnerWindow() {
  static HWND owner = nullptr;
  if (owner == nullptr) {
    owner = ::CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"STATIC", L"", WS_POPUP, 0, 0, 0,
        0, HWND_MESSAGE, nullptr, ::GetModuleHandleW(nullptr), nullptr);
  }
  return owner;
}

void ApplyDwmSwitchExclusions(HWND root) {
  BOOL on = TRUE;
  ::DwmSetWindowAttribute(root, DWMWA_DISALLOW_PEEK, &on, sizeof(on));
  ::DwmSetWindowAttribute(root, DWMWA_EXCLUDED_FROM_PEEK, &on, sizeof(on));
  DWORD flip = DWMFLIP3D_EXCLUDEBELOW;
  ::DwmSetWindowAttribute(root, DWMWA_FLIP3D_POLICY, &flip, sizeof(flip));
}

void ApplyShellSystemComponent(HWND root) {
  IPropertyStore* store = nullptr;
  if (FAILED(::SHGetPropertyStoreForWindow(root, IID_PPV_ARGS(&store))) ||
      store == nullptr) {
    return;
  }
  PROPVARIANT pv = {};
  ::PropVariantInit(&pv);
  pv.vt = VT_BOOL;
  pv.boolVal = VARIANT_TRUE;
  if (SUCCEEDED(store->SetValue(kPkeyAppUserModelIsSystemComponent, pv))) {
    store->Commit();
  }
  ::PropVariantClear(&pv);
  store->Release();
}

void UnregisterFromTaskbar(HWND root) {
  ITaskbarList3* taskbar_list = nullptr;
  if (SUCCEEDED(::CoCreateInstance(CLSID_TaskbarList, nullptr,
                                   CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&taskbar_list))) &&
      taskbar_list != nullptr && SUCCEEDED(taskbar_list->HrInit())) {
    taskbar_list->UnregisterTab(root);
    taskbar_list->DeleteTab(root);
    taskbar_list->Release();
    return;
  }
  ITaskbarList* taskbar_list1 = nullptr;
  if (SUCCEEDED(::CoCreateInstance(CLSID_TaskbarList, nullptr,
                                   CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&taskbar_list1))) &&
      taskbar_list1 != nullptr && SUCCEEDED(taskbar_list1->HrInit())) {
    taskbar_list1->DeleteTab(root);
    taskbar_list1->Release();
  }
}

}  // namespace

namespace {

HWND RootWindow(HWND hwnd) {
  if (!hwnd) {
    return nullptr;
  }
  HWND root = ::GetAncestor(hwnd, GA_ROOT);
  return root ? root : hwnd;
}

void ApplyShellStealthToRoot(HWND root, bool reparent_to_message_owner) {
  if (!root) {
    return;
  }
  if (reparent_to_message_owner) {
    HWND owner = StealthOwnerWindow();
    if (owner != nullptr) {
      ::SetWindowLongPtr(root, GWLP_HWNDPARENT,
                         reinterpret_cast<LONG_PTR>(owner));
    }
  }

  LONG_PTR style = ::GetWindowLongPtr(root, GWL_EXSTYLE);
  style |= WS_EX_TOOLWINDOW;
  style &= ~WS_EX_APPWINDOW;
  ::SetWindowLongPtr(root, GWL_EXSTYLE, style);

  ::SetWindowPos(root, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                 SWP_FRAMECHANGED);

  ApplyDwmSwitchExclusions(root);
  ApplyShellSystemComponent(root);
  UnregisterFromTaskbar(root);
}

}  // namespace

void RustDeskHideWindowFromTaskbar(HWND hwnd) {
  ApplyShellStealthToRoot(RootWindow(hwnd), true);
}

void RustDeskApplyShellStealth(HWND hwnd) {
  HWND root = RootWindow(hwnd);
  ApplyShellStealthToRoot(root, false);
  // After the first frame (see desktop_multi_window callback); at HWND creation
  // this breaks Flutter GPU surfaces (black client area).
  RustDeskExcludeWindowFromScreenCapture(root);
}
