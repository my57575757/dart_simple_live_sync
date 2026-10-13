#ifndef RUNNER_NATIVE_EDIT_HOST_H_
#define RUNNER_NATIVE_EDIT_HOST_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <windows.h>

#include <string>

// 承载一个盖在 Flutter 视图上的无框单行 EDIT 子窗口。
// EDIT 持有 ImmCreateContext 自建的专属 HIMC，与引擎窗口的 IMM32<->TSF
// 会话隔离：引擎侧桥僵死（flutter/flutter #190042）后此窗口仍可正常组字。
// 所有方法只在顶层窗口线程调用。
class NativeEditHost {
 public:
  NativeEditHost(HWND parent, HWND engine_window,
                 flutter::BinaryMessenger* messenger);
  ~NativeEditHost();

  bool visible() const { return shown_; }

  // 顶层窗口 WA_ACTIVE/WA_CLICKACTIVE 且 EDIT 可见时调用，夺回焦点，
  // 阻止基类把焦点还给引擎子窗口。
  void Refocus();

  // 转发父窗口收到的 WM_CTLCOLOREDIT；非本 EDIT 返回 nullptr。
  HBRUSH HandleCtlColor(HDC dc, HWND child);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<>& call,
      std::unique_ptr<flutter::MethodResult<>> result);
  bool EnsureCreated();
  void Show(const flutter::EncodableMap& args);
  void Hide(bool notify_dart);
  void SetText(const std::string& utf8);
  std::string GetText() const;
  void Submit();
  void ApplyRegion(int width, int height);
  static LRESULT CALLBACK EditWndProc(HWND hwnd, UINT message,
                                      WPARAM wparam, LPARAM lparam);

  HWND parent_;
  HWND engine_window_;
  HWND edit_ = nullptr;
  WNDPROC original_edit_proc_ = nullptr;
  HIMC himc_ = nullptr;

  bool shown_ = false;
  int radius_px_ = 0;
  int pad_x_px_ = 0;
  COLORREF bg_color_ = RGB(255, 255, 255);
  COLORREF text_color_ = RGB(0, 0, 0);
  COLORREF hint_color_ = RGB(128, 128, 128);
  HBRUSH bg_brush_ = nullptr;
  HFONT font_ = nullptr;
  std::wstring hint_;

  std::unique_ptr<flutter::MethodChannel<>> channel_;
};

#endif  // RUNNER_NATIVE_EDIT_HOST_H_
