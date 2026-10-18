#include "win32_snap_eligibility.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <propkey.h>
#include <propvarutil.h>
#include <propsys.h>
#include <shobjidl_core.h>

#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "propsys.lib")
#pragma comment(lib, "shell32.lib")

#ifndef DWMWA_CLOAK
#define DWMWA_CLOAK 13
#endif

// 与 main.cpp 的 SetCurrentProcessExplicitAppUserModelID 同值。
// Snap Assist 会优先读「每个窗口」属性存储里的 PKEY_AppUserModel_ID，
// 仅设进程级 AUMID 不够。
static constexpr wchar_t kAppUserModelID[] = L"SimpleLive.Desktop";

void EnsureSnapEligible(HWND hwnd) {
  if (hwnd == nullptr || !IsWindow(hwnd)) {
    return;
  }

  // WS_EX_APPWINDOW 强制进任务栏/贴靠候选；WS_EX_TOOLWINDOW 会把窗口踢出
  // Snap Assist 过滤条件，必须清掉。
  LONG ex_style = GetWindowLong(hwnd, GWL_EXSTYLE);
  ex_style |= WS_EX_APPWINDOW;
  ex_style &= ~WS_EX_TOOLWINDOW;
  SetWindowLong(hwnd, GWL_EXSTYLE, ex_style);

  // 逐窗写入 AppUserModelID：主窗 FLUTTER_RUNNER_WIN32_WINDOW 与
  // desktop_multi_window 子窗 FLUTTER_MULTI_WINDOW_WIN32_WINDOW 窗口类不同，
  // 无逐窗 AUMID 时 Snap Assist 不把 4 窗收成「同一软件」，退回 MRU 只显示
  // 最近 3 个。
  IPropertyStore* prop_store = nullptr;
  if (SUCCEEDED(::SHGetPropertyStoreForWindow(hwnd, IID_PPV_ARGS(&prop_store)))) {
    PROPVARIANT pv;
    if (SUCCEEDED(::InitPropVariantFromString(kAppUserModelID, &pv))) {
      prop_store->SetValue(PKEY_AppUserModel_ID, pv);
      prop_store->Commit();
      ::PropVariantClear(&pv);
    }
    prop_store->Release();
  }

  // 防 cloak：被 DWM 隐身的窗口不进 Snap Assist 候选池。
  BOOL uncloaked = FALSE;
  ::DwmSetWindowAttribute(hwnd, DWMWA_CLOAK, &uncloaked, sizeof(uncloaked));

  // ITaskbarList 登记：与 window_manager 的 setSkipTaskbar(false) 同路径，
  // 保证 DWM/任务栏侧把本窗当成正式应用窗口，而非隐藏/工具窗。
  ITaskbarList* taskbar = nullptr;
  HRESULT hr = ::CoCreateInstance(CLSID_TaskbarList, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_ITaskbarList,
                                  reinterpret_cast<void**>(&taskbar));
  if (SUCCEEDED(hr) && taskbar != nullptr) {
    if (SUCCEEDED(taskbar->HrInit())) {
      taskbar->AddTab(hwnd);
    }
    taskbar->Release();
  }

  // SWP_FRAMECHANGED：强制非客户区/窗口样式变更对 DWM 生效，否则部分
  // Win11 构建上贴靠布局会漏掉刚注册的窗口。
  RECT rect;
  if (GetWindowRect(hwnd, &rect)) {
    SetWindowPos(hwnd, nullptr, rect.left, rect.top, 0, 0,
                 SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOMOVE | SWP_NOSIZE |
                     SWP_NOACTIVATE | SWP_FRAMECHANGED);
  }
}

// WM_SHOWWINDOW 时重刷贴靠资格，兜住 ShowWindowAsync 异步竞态。
static LRESULT CALLBACK SnapEligibleSubclassProc(HWND hwnd, UINT msg,
                                                 WPARAM wparam, LPARAM lparam,
                                                 UINT_PTR subclass_id,
                                                 DWORD_PTR ref_data) {
  if (msg == WM_SHOWWINDOW && wparam != FALSE) {
    EnsureSnapEligible(hwnd);
  } else if (msg == WM_NCDESTROY) {
    ::RemoveWindowSubclass(hwnd, SnapEligibleSubclassProc, subclass_id);
  }
  return ::DefSubclassProc(hwnd, msg, wparam, lparam);
}

void HookSnapEligibleOnShow(HWND hwnd) {
  EnsureSnapEligible(hwnd);
  ::SetWindowSubclass(hwnd, SnapEligibleSubclassProc, 1, 0);
}
