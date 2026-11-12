#include "screen_capture_exclude.h"

#include <windows.h>

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

namespace {

bool WindowsBuildAtLeast(DWORD build_number) {
  HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll");
  if (!ntdll) {
    return false;
  }
  using RtlGetVersionFn = LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
  auto rtl_get_version = reinterpret_cast<RtlGetVersionFn>(
      ::GetProcAddress(ntdll, "RtlGetVersion"));
  if (!rtl_get_version) {
    return false;
  }
  OSVERSIONINFOW info = {};
  info.dwOSVersionInfoSize = sizeof(info);
  if (rtl_get_version(reinterpret_cast<PRTL_OSVERSIONINFOW>(&info)) != 0) {
    return false;
  }
  if (info.dwMajorVersion < 10) {
    return false;
  }
  return info.dwBuildNumber >= build_number;
}

}  // namespace

bool RustDeskExcludeWindowFromScreenCapture(HWND hwnd) {
  if (!hwnd || !WindowsBuildAtLeast(19041)) {
    return false;
  }
  HWND root = ::GetAncestor(hwnd, GA_ROOT);
  if (!root) {
    root = hwnd;
  }
  using SetWindowDisplayAffinityFn = BOOL(WINAPI*)(HWND, DWORD);
  auto set_affinity = reinterpret_cast<SetWindowDisplayAffinityFn>(::GetProcAddress(
      ::GetModuleHandleW(L"user32.dll"), "SetWindowDisplayAffinity"));
  if (!set_affinity) {
    return false;
  }
  return set_affinity(root, WDA_EXCLUDEFROMCAPTURE) != FALSE;
}
