#ifndef RUNNER_WIN32_SNAP_ELIGIBILITY_H_
#define RUNNER_WIN32_SNAP_ELIGIBILITY_H_

#include <Windows.h>

// 让顶层窗口以「普通应用窗口」身份进入 Win11 贴靠/Snap Assist 候选池：
// 显式 WS_EX_APPWINDOW、清 WS_EX_TOOLWINDOW、ITaskbarList::AddTab 登记、
// SWP_FRAMECHANGED 强制 DWM 重注册。主窗与 desktop_multi_window 子窗都要调。
void EnsureSnapEligible(HWND hwnd);

#endif  // RUNNER_WIN32_SNAP_ELIGIBILITY_H_
