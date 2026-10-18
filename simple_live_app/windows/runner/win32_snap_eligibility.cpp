#include "win32_snap_eligibility.h"

#include <shobjidl_core.h>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")

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
