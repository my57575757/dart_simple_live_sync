#ifndef RUNNER_NATIVE_EDIT_HOST_H_
#define RUNNER_NATIVE_EDIT_HOST_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <windows.h>

#include <string>

// 承载一个盖在 Flutter 视图上的无框单行输入框。
//
// 结构：WS_POPUP 顶层容器（owner 为宿主顶层窗口）+ 其中铺满的 EDIT 子窗口。
// 之所以不用 WS_CHILD 直接嵌进宿主窗口：Flutter 引擎视图走 DirectComposition
// 合成，经典 Win32 兄弟窗口的 z-order 对它无效，GDI 子窗口会被引擎的下一帧
// 盖掉（实测 EDIT 表面已正确绘制但屏幕上只闪一下）。被宿主窗口拥有的顶层
// popup 位于所有子窗口（含 DComp 层）之上，才能稳定可见。
//
// EDIT 持有 ImmCreateContext 自建的专属 HIMC，与引擎窗口的 IMM32<->TSF
// 会话隔离：引擎侧桥僵死（flutter/flutter #190042）后此窗口仍可正常组字。
//
// 每个顶层窗口一个 host，按 popup 的 GWLP_USERDATA 寻址；不设进程单例。
// owner 的移动/激活/销毁由 SetWindowSubclass 自行处理，宿主 MessageHandler
// 无需转发。所有方法只在顶层窗口线程调用。
class NativeEditHost {
 public:
  // 自注册自释放：构造时对 parent 挂 subclass，owner WM_NCDESTROY 时自行
  // 拆除并 delete this，调用方不持有指针。
  NativeEditHost(HWND parent, HWND engine_window,
                 flutter::BinaryMessenger* messenger);
  ~NativeEditHost();

  bool visible() const { return shown_; }

  // 输入框可见时夺回焦点，阻止基类把焦点还给引擎子窗口。
  void Refocus();

  // 宿主窗口移动/缩放后调用：把 popup 重新贴到目标矩形的屏幕坐标。
  void OnOwnerMoved();

  // 转发 popup 容器收到的 WM_CTLCOLOREDIT；非本 EDIT 返回 nullptr。
  HBRUSH HandleCtlColor(HDC dc, HWND child);

  // popup 容器窗口过程（注册窗口类需要外部可见）。
  static LRESULT CALLBACK PopupWndProc(HWND hwnd, UINT message,
                                       WPARAM wparam, LPARAM lparam);

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
  void LayoutPopup(int x, int y, int w, int h);
  void ApplyRegion(int width, int height);
  // 单行 EDIT 忽略 EM_SETRECT 的纵向分量、文字恒顶对齐。故不让 EDIT 铺满
  // popup，而是把 EDIT 高度收为约一行行高、在 popup 内垂直居中放置。
  void LayoutEdit(int popup_h);
  static LRESULT CALLBACK EditWndProc(HWND hwnd, UINT message,
                                      WPARAM wparam, LPARAM lparam);
  // owner 顶层窗口的 subclass 过程：自处理移动/激活，NCDESTROY 时自释放。
  static LRESULT CALLBACK OwnerSubclassProc(HWND hwnd, UINT message,
                                            WPARAM wparam, LPARAM lparam,
                                            UINT_PTR subclass_id,
                                            DWORD_PTR ref_data);

  HWND parent_;
  HWND engine_window_;
  HWND popup_ = nullptr;
  HWND edit_ = nullptr;
  WNDPROC original_edit_proc_ = nullptr;
  HIMC himc_ = nullptr;
  // SetWindowSubclass 的返回值（TRUE=1 亦即 uIdSubclass），0 表示未挂上。
  UINT_PTR subclass_id_ = 0;

  bool shown_ = false;
  bool has_focus_ = false;
  // popup 目标矩形（主窗口客户区物理像素坐标），供 OnOwnerMoved 重定位。
  int rect_x_ = 0;
  int rect_y_ = 0;
  int rect_w_ = 0;
  int rect_h_ = 0;
  int edit_h_ = 0;  // EDIT 单行高度（≈字体行高），用于垂直居中
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
