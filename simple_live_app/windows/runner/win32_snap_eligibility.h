#ifndef RUNNER_WIN32_SNAP_ELIGIBILITY_H_
#define RUNNER_WIN32_SNAP_ELIGIBILITY_H_

#include <Windows.h>

// 让顶层窗口以「普通应用窗口」身份进入 Win11 贴靠/Snap Assist 候选池：
// 显式 WS_EX_APPWINDOW、清 WS_EX_TOOLWINDOW、逐窗 AppUserModelID、
// ITaskbarList::AddTab 登记、SWP_FRAMECHANGED 强制 DWM 重注册。
void EnsureSnapEligible(HWND hwnd);

// 在窗口上挂 subclass：每次 WM_SHOWWINDOW 时重跑 EnsureSnapEligible。
// 用于兜住 window_manager Show() 走 ShowWindowAsync 的异步竞态——
// Snap Assist 在窗口尚未真正可见时查询会漏掉该窗。
void HookSnapEligibleOnShow(HWND hwnd);

#endif  // RUNNER_WIN32_SNAP_ELIGIBILITY_H_
