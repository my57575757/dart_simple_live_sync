#ifndef RUNNER_NATIVE_EDIT_HOST_H_
#define RUNNER_NATIVE_EDIT_HOST_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <windows.h>

#include <memory>

// 承载一个盖在 Flutter 视图上的无框单行输入框。
//
// 架构（独立线程输入窗）：
// popup（WS_POPUP 顶层容器，owner 为宿主顶层窗口）与其中铺满的 RichEdit 5.0
// （msftedit.dll，RICHEDIT50W）整体运行在一条专用 STA 输入线程上。该线程自行
// CoInitializeEx 并显式 ITfThreadMgr::Activate，持有独立于 Flutter UI 线程的
// TSF manager 与搜狗 TIP 实例。UI 线程内在编辑框获焦期间切语言导致的 TIP 按键
// 接收器毒化（字母直通、候选窗不弹、进程内不可恢复）因此无法波及输入线程。
//
// 不用 WS_CHILD 直接嵌入宿主窗口的原因不变：Flutter 引擎走 DirectComposition
// 合成，经典 Win32 兄弟窗口的 z-order 对它无效，GDI 子窗口会被下一帧盖掉；被
// 宿主拥有的顶层 popup 位于所有子窗口（含 DComp 层）之上才能稳定可见。
//
// 跨线程一律消息封送：
//  - UI→输入：Send/PostMessage 到 popup（show/commit 同步往返，其余异步）
//  - 输入→UI：只 PostMessage 到 UI 线程的 message-only 回调窗，绝不同步回送，
//    杜绝双向 SendMessage 死锁；MethodChannel InvokeMethod 只在 UI 线程执行
//
// 每个顶层窗口一个 host，owner 的移动/激活/销毁由 SetWindowSubclass 自行处理，
// 宿主 MessageHandler 无需转发；owner WM_NCDESTROY 时停掉输入线程并 delete this。
class NativeEditHost {
 public:
  // 自注册自释放：构造时对 parent 挂 subclass，owner WM_NCDESTROY 时自行
  // 拆除、停输入线程并 delete this，调用方不持有指针。
  NativeEditHost(HWND parent, HWND engine_window,
                 flutter::BinaryMessenger* messenger);
  ~NativeEditHost();

  // UI 线程 message-only 回调窗的窗口过程：输入线程的 submit/closed 通知
  // 经 PostMessage 落到这里，在 UI 线程上执行 MethodChannel InvokeMethod。
  static LRESULT CALLBACK CallbackWndProc(HWND hwnd, UINT message,
                                          WPARAM wparam, LPARAM lparam);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<>& call,
      std::unique_ptr<flutter::MethodResult<>> result);
  // 首次 show 时懒启动输入线程，等待其完成 popup/EDIT 创建与 TSF 激活。
  bool EnsureInputThread();
  // 同步通知输入线程销毁窗口并退出消息循环，回收线程句柄；幂等。
  void TeardownInputThread();
  static DWORD WINAPI InputThreadMain(LPVOID param);

  // owner 顶层窗口的 subclass 过程：自处理移动/激活，NCDESTROY 时自释放。
  static LRESULT CALLBACK OwnerSubclassProc(HWND hwnd, UINT message,
                                            WPARAM wparam, LPARAM lparam,
                                            UINT_PTR subclass_id,
                                            DWORD_PTR ref_data);

  HWND parent_;
  HWND engine_window_;
  // UI 线程 message-only 窗口，接收输入线程 Post 回来的 submit/closed。
  HWND callback_hwnd_ = nullptr;
  // 输入线程 message-only 命令窗句柄，由输入线程在 ready event 前置位；UI
  // 线程等到事件后才读取，据此向输入线程封送命令。命令窗与输入线程同寿、
  // 无 owner，不会被宿主窗口销毁链连带销毁。nullptr 表示线程未启动或失败。
  HWND input_cmd_ = nullptr;
  HANDLE thread_ = nullptr;
  HANDLE ready_event_ = nullptr;
  DWORD input_tid_ = 0;
  // SetWindowSubclass 的返回值（TRUE=1 亦即 uIdSubclass），0 表示未挂上。
  UINT_PTR subclass_id_ = 0;

  std::unique_ptr<flutter::MethodChannel<>> channel_;
};

#endif  // RUNNER_NATIVE_EDIT_HOST_H_
