#ifndef RUNNER_NATIVE_EDIT_HOST_H_
#define RUNNER_NATIVE_EDIT_HOST_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <windows.h>

#include <string>

// 承载一个盖在 Flutter 视图上的无框单行输入框。
//
// 结构：WS_POPUP 顶层容器（owner 为宿主顶层窗口）+ 其中铺满的 RichEdit
// 5.0（msftedit.dll，RICHEDIT50W）子窗口。
// 之所以不用 WS_CHILD 直接嵌进宿主窗口：Flutter 引擎视图走 DirectComposition
// 合成，经典 Win32 兄弟窗口的 z-order 对它无效，GDI 子窗口会被引擎的下一帧
// 盖掉（实测 EDIT 表面已正确绘制但屏幕上只闪一下）。被宿主窗口拥有的顶层
// popup 位于所有子窗口（含 DComp 层）之上，才能稳定可见。
//
// 之所以不用 legacy EDIT：EDIT 的 TSF 编辑文档经 IMM32 桥管理，搜狗在
// 切语言/跨窗后会概率性永久毒化（字母直通、候选窗不弹），焦点/HIMC/窗口
// 重建均无法确定性恢复。RichEdit 自带现代 TSF edit context，从架构上绕开。
//
// RichEdit 另持 ImmCreateContext 自建的专属 HIMC 与引擎窗口隔离（引擎侧
// IMM32<->TSF 桥僵死见 flutter/flutter #190042），并作为 DIRECT_KEY 指纹
// 惰性重建兜底。
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
  // 把字数上限、底色、文字颜色、字体、左右内边距应用到当前 RichEdit：
  // 创建后与每次 Show（样式参数可能变化）时各调一次。
  void ApplyEditStyle();
  // EDIT 获焦或输入语言切换后，detach/reattach 专属 HIMC 强制 IME 重走
  // activate/focus：跨进程切窗后 TSF 文档上下文可能半初始化（HIMC 打开态与
  // 关联句柄都正常，但搜狗字母直通、候选窗不弹）。
  // reason 仅写入常驻 IME 诊断日志，标识触发路径（setfocus/langchange）。
  void ReattachImeContext(const char* reason);
  // EDIT 在英语布局下首次获焦后切到搜狗会导致 TSF 文档永久不可用：
  // 销毁当前 EDIT 与专属 HIMC，原样新建一个 EDIT（保留文本/选区/位置），
  // 使新窗口在搜狗活动期间首次获焦、TSF 重新建档。仅在 UI 线程调用。
  void RecreateEditWindow(const char* reason);
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
  // 当前 EDIT 窗口的获焦次数：0=首次获焦（不 reattach，避免打断 TSF 对
  // 可见新窗口的文档初始化）。
  int edit_focus_seq_ = 0;
  // 重建请求已 PostMessage、尚未执行：兼作「毒化键 WM_CHAR 吞除窗口」标志——
  // DIRECT_KEY 的字母 WM_CHAR 在其 WM_KEYDOWN 之前已入队，靠它在 WM_CHAR
  // 里识别并吞掉。
  bool recreate_pending_ = false;
  // EDIT 重建（直通惰性自愈）期间 popup 临时持有键盘焦点，其 WM_SETFOCUS
  // 暂不把焦点抢回即将销毁的旧 EDIT。
  bool healing_bounce_ = false;
  // WM_MOUSEACTIVATE 检出前台属于其他进程时武装；popup 的 WM_SETFOCUS
  // redirect 分支消费它，Post 一拍后强制 TSF 焦点重建（见 kMsgTsfReassert）。
  bool tsf_reassert_pending_ = false;
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
