#include "native_edit_host.h"

#include <commctrl.h>
#include <imm.h>
#include <objbase.h>
// initguid 必须在 msctf.h 前：让 CLSID_TF_ThreadMgr 在本编译单元内成为定义，
// 免去额外链接 uuid.lib。
#include <initguid.h>
#include <msctf.h>
#include <richedit.h>

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>

// SetWindowSubclass 在 comctl32；CMake 未显式链接，这里补齐。
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "ole32.lib")

namespace {

constexpr int kMaxChars = 200;
constexpr wchar_t kFontFace[] = L"Microsoft YaHei UI";
// 输入控件窗口类：RichEdit 5.0（msftedit.dll，RICHEDIT50W）自带符合现代 TSF
// 的 edit context，不依赖 legacy EDIT 那套 IMM32 文档桥。
constexpr wchar_t kEditClass[] = L"RICHEDIT50W";
constexpr wchar_t kPopupClass[] = L"SimpleLiveNativeEditPopup";
constexpr wchar_t kCallbackClass[] = L"SimpleLiveNativeEditCallback";
// 输入线程的 message-only 命令窗：与线程同寿、无 owner，宿主销毁链不会
// 连带销毁它，teardown 的 quit 命令因此永远可达，避免线程卡死在消息循环。
constexpr wchar_t kInputCmdClass[] = L"SimpleLiveNativeInputCmd";
// SetWindowSubclass 的 uIdSubclass；返回值恒为 1，与 subclass_id_ 对齐。
constexpr UINT_PTR kOwnerSubclassId = 1;

// UI 线程 → 输入线程的封送命令（目标为输入线程 popup）。
constexpr UINT kCmdShow = WM_APP + 1;
constexpr UINT kCmdHide = WM_APP + 2;
constexpr UINT kCmdSetText = WM_APP + 3;
// 同步往返：返回值为堆分配 std::wstring*，UI 线程取走文本后负责 delete。
constexpr UINT kCmdCommit = WM_APP + 4;
constexpr UINT kCmdRelayout = WM_APP + 5;
constexpr UINT kCmdOwnerDeactivate = WM_APP + 6;
constexpr UINT kCmdQuit = WM_APP + 7;
// 输入线程 → UI 线程的回调（目标为 message-only 回调窗）。
// kCbSubmit 的 wParam 为堆分配 std::string*（UTF-8），UI 线程取走后 delete。
constexpr UINT kCbSubmit = WM_APP + 10;
constexpr UINT kCbClosed = WM_APP + 11;

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  int len = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring out(static_cast<size_t>(len), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      out.data(), len);
  return out;
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  int len = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                static_cast<int>(wide.size()), nullptr, 0,
                                nullptr, nullptr);
  std::string out(static_cast<size_t>(len), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                      static_cast<int>(wide.size()), out.data(), len, nullptr,
                      nullptr);
  return out;
}

double AsDouble(const flutter::EncodableValue& value) {
  if (const auto* d = std::get_if<double>(&value)) {
    return *d;
  }
  if (const auto* i = std::get_if<int32_t>(&value)) {
    return *i;
  }
  if (const auto* i64 = std::get_if<int64_t>(&value)) {
    return static_cast<double>(*i64);
  }
  return 0.0;
}

int AsInt(const flutter::EncodableValue& value) {
  return static_cast<int>(AsDouble(value));
}

// 颜色（0xAARRGGBB）恒大于 INT32_MAX，绝不能像几何值那样经 double->int32
// 强转（MSVC 溢出折叠为 0x80000000，RGB 通道全 0 变黑）。直接按位取 uint32。
uint32_t AsUInt32(const flutter::EncodableValue& value) {
  if (const auto* i = std::get_if<int32_t>(&value)) {
    return static_cast<uint32_t>(*i);
  }
  if (const auto* i64 = std::get_if<int64_t>(&value)) {
    return static_cast<uint32_t>(*i64);
  }
  if (const auto* d = std::get_if<double>(&value)) {
    return static_cast<uint32_t>(*d);
  }
  return 0;
}

COLORREF RgbFromArgb(uint32_t v) {
  return RGB(v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF);
}

// IME 故障常驻取证：跨线程/切语言后搜狗字母直通、候选窗不弹是焦点/激活时序
// 竞态，事后无法复盘。关键事件落 %TEMP%\simple_live_ime.log，进程首次写时
// 截断重建（只留本进程），事件低频，无需轮转。内容全 ASCII，规避日志编码。
// tid 字段天然区分 Flutter UI 线程与独立输入线程。
void ImeDiagLog(const char* fmt, ...) {
  static wchar_t log_path[MAX_PATH] = {};
  static DWORD creation = OPEN_ALWAYS;
  if (log_path[0] == L'\0') {
    const DWORD n = GetTempPathW(MAX_PATH, log_path);
    if (n == 0 || n >= MAX_PATH) {
      return;
    }
    wcscat_s(log_path, L"simple_live_ime.log");
    creation = CREATE_ALWAYS;
  }

  char line[1200];
  const int head = _snprintf_s(line, _countof(line), _TRUNCATE,
                               "%llu tid=%lu ",
                               static_cast<unsigned long long>(GetTickCount64()),
                               GetCurrentThreadId());
  if (head > 0) {
    va_list args;
    va_start(args, fmt);
    vsnprintf_s(line + head, _countof(line) - static_cast<size_t>(head),
                _TRUNCATE, fmt, args);
    va_end(args);
  }
  size_t used = strnlen(line, _countof(line));
  if (used + 2 < _countof(line)) {
    line[used++] = '\r';
    line[used++] = '\n';
  }

  HANDLE file = CreateFileW(log_path, FILE_APPEND_DATA,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            creation, FILE_ATTRIBUTE_NORMAL, nullptr);
  creation = OPEN_ALWAYS;
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  DWORD written = 0;
  WriteFile(file, line, static_cast<DWORD>(used), &written, nullptr);
  CloseHandle(file);
}

// 记一条窗口身份：类名（非 ASCII 压成 '?'，日志按字节写入）、所属线程、
// owner、是否 WS_CHILD、是否可见。焦点跳到陌生窗口时用于判定它是别的 Flutter
// 顶层窗、引擎子窗还是 IME/外部应用窗口。
void ImeDiagLogWnd(const char* tag, HWND wnd) {
  char cls[80] = {};
  DWORD wnd_tid = 0;
  HWND owner = nullptr;
  LONG_PTR style = 0;
  BOOL visible = FALSE;
  if (wnd) {
    wchar_t wcls[80] = {};
    if (GetClassNameW(wnd, wcls, _countof(wcls)) > 0) {
      for (size_t i = 0; i < _countof(wcls) && wcls[i]; ++i) {
        cls[i] = wcls[i] < 128 ? static_cast<char>(wcls[i]) : '?';
      }
    }
    wnd_tid = GetWindowThreadProcessId(wnd, nullptr);
    owner = GetWindow(wnd, GW_OWNER);
    style = GetWindowLongPtrW(wnd, GWL_STYLE);
    visible = IsWindowVisible(wnd);
  }
  ImeDiagLog("%s wnd=%p cls=%s tid=%lu owner=%p child=%d vis=%d", tag, wnd,
             cls, static_cast<unsigned long>(wnd_tid), owner,
             (style & WS_CHILD) ? 1 : 0, visible ? 1 : 0);
}

// 单行可横滚、禁止 OLE 拖放；WS_CHILD 必备。首次调用时驻留 msftedit.dll。
HWND CreateEditControl(HWND parent, int x, int y, int w, int h) {
  static const HMODULE msftedit = LoadLibraryW(L"msftedit.dll");
  if (!msftedit) {
    return nullptr;
  }
  return CreateWindowExW(0, kEditClass, L"",
                         WS_CHILD | ES_AUTOHSCROLL | ES_NOOLEDRAGDROP, x, y, w,
                         h, parent, nullptr, GetModuleHandleW(nullptr),
                         nullptr);
}

// show 命令的跨线程参数包：UI 线程解析 EncodableMap 后堆分配，随 kCmdShow
// 所有权转移给输入线程，处理完毕由输入线程 delete。
struct ShowArgs {
  int x = 0;
  int y = 0;
  int w = 0;
  int h = 0;
  int radius = 0;
  int pad_x = 0;
  double font_px = 16.0;
  COLORREF bg = RGB(255, 255, 255);
  COLORREF text_color = RGB(0, 0, 0);
  COLORREF hint_color = RGB(128, 128, 128);
  std::wstring hint_text;
  std::wstring initial_text;
};

// 输入线程启动参数（栈分配，UI 线程以 ready event 等待后即失效）。
struct ThreadStartup {
  HWND parent;
  HWND engine_window;
  HWND callback_hwnd;
  HANDLE ready;
  HWND* cmd_out;
};

// 前向声明：Register*Class 的定义在类之后（窗口过程是类的静态成员）。
void RegisterPopupClass();
void RegisterInputCmdClass();

// 输入线程的全部状态。对象在输入线程上创建并销毁，除构造时传入的三个 HWND
// 外，UI 线程不触碰任何字段——跨线程交互只走 popup 的窗口消息。
class InputThreadContext {
 public:
  InputThreadContext(HWND parent, HWND engine_window, HWND callback_hwnd)
      : parent_(parent),
        engine_window_(engine_window),
        callback_hwnd_(callback_hwnd) {
    bg_brush_ = CreateSolidBrush(bg_color_);
  }

  ~InputThreadContext() {
    if (edit_ && IsWindow(edit_)) {
      SetWindowLongPtrW(edit_, GWLP_WNDPROC,
                        reinterpret_cast<LONG_PTR>(original_edit_proc_));
    }
    if (popup_ && IsWindow(popup_)) {
      // 连带销毁其中的 EDIT。
      DestroyWindow(popup_);
    }
    if (cmd_hwnd_ && IsWindow(cmd_hwnd_)) {
      DestroyWindow(cmd_hwnd_);
    }
    popup_ = nullptr;
    edit_ = nullptr;
    cmd_hwnd_ = nullptr;
    if (bg_brush_) {
      DeleteObject(bg_brush_);
      bg_brush_ = nullptr;
    }
    if (font_) {
      DeleteObject(font_);
      font_ = nullptr;
    }
  }

  bool Initialize() {
    RegisterInputCmdClass();
    cmd_hwnd_ = CreateWindowExW(0, kInputCmdClass, L"", 0, 0, 0, 0, 0,
                                HWND_MESSAGE, nullptr,
                                GetModuleHandleW(nullptr), nullptr);
    if (!cmd_hwnd_) {
      ImeDiagLog("INPUT_CMD_CREATE_FAIL err=%lu", GetLastError());
      return false;
    }
    SetWindowLongPtrW(cmd_hwnd_, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(this));

    RegisterPopupClass();
    // WS_EX_NOACTIVATE：点击/显示不抢占主窗口激活态；WS_EX_TOOLWINDOW：
    // 不进任务栏与 Alt-Tab。owner 为 UI 线程的宿主窗口，popup 恒在其所有
    // 子窗口之上（跨线程 owner 关系合法，消息队列归属创建线程）。
    popup_ = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, kPopupClass,
                             L"", WS_POPUP | WS_CLIPCHILDREN, 0, 0, 10, 10,
                             parent_, nullptr, GetModuleHandleW(nullptr),
                             nullptr);
    if (!popup_) {
      ImeDiagLog("INPUT_POPUP_CREATE_FAIL err=%lu", GetLastError());
      return false;
    }
    SetWindowLongPtrW(popup_, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(this));
    edit_ = CreateEditControl(popup_, 0, 0, 10, 10);
    if (!edit_) {
      DestroyWindow(popup_);
      popup_ = nullptr;
      ImeDiagLog("INPUT_EDIT_CREATE_FAIL err=%lu", GetLastError());
      return false;
    }
    original_edit_proc_ = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(
        edit_, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(&EditWndProc)));
    ApplyEditStyle();
    ImeDiagLog("INPUT_READY popup=%p edit=%p", popup_, edit_);
    return true;
  }

  HWND cmd_hwnd() const { return cmd_hwnd_; }

  bool HandleShow(const ShowArgs* args) {
    if (!popup_ || !edit_ || !args) {
      return false;
    }
    if (args->bg != bg_color_ || !bg_brush_) {
      bg_color_ = args->bg;
      if (bg_brush_) {
        DeleteObject(bg_brush_);
      }
      bg_brush_ = CreateSolidBrush(bg_color_);
    }
    text_color_ = args->text_color;
    hint_color_ = args->hint_color;
    radius_px_ = args->radius;
    pad_x_px_ = args->pad_x;
    hint_ = args->hint_text;

    HFONT new_font =
        CreateFontW(-static_cast<int>(std::lround(args->font_px)), 0, 0, 0,
                    FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                    OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                    CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, kFontFace);
    if (new_font) {
      if (font_) {
        DeleteObject(font_);
      }
      font_ = new_font;
    }
    // 字体、底色、文字色、内边距、字数上限统一下发（RichEdit 不吃 WM_CTLCOLOR）。
    ApplyEditStyle();
    LayoutPopup(args->x, args->y, args->w, args->h);
    // 文本只在「从隐藏态打开」时同步一次；relayout 会带着 shown_==true 重入，
    // 那时 SetWindowText 会清空用户正在输入的内容。发送后清空走 setText 通道。
    if (!shown_) {
      SetWindowTextW(edit_, args->initial_text.c_str());
    }

    ShowWindow(popup_, SW_SHOWNOACTIVATE);
    // EDIT 是 WS_CHILD，创建后默认隐藏，必须随 popup 一起显示。
    ShowWindow(edit_, SW_SHOWNOACTIVATE);
    // owned 窗口理论上恒在 owner 之上，显式再提一次以防被 DComp 表面压住。
    SetWindowPos(popup_, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    shown_ = true;
    // 仅当前台就是 owner/popup 本窗口链时才把键盘焦点交给 EDIT。app 在后台
    // 时 Dart 仍可能因布局变化/重建重发 show：后台抢焦会让 TSF 建半初始化
    // 文档。后台只显示不抢焦；用户真点击时 WM_MOUSEACTIVATE 显式主导焦点。
    // EDIT 属本线程窗口，SetFocus 无需 AttachThreadInput。
    HWND fg = GetForegroundWindow();
    const bool foreground_ours = (fg == parent_ || fg == popup_);
    if (foreground_ours) {
      SetFocus(edit_);
    }
    ImeDiagLog("SHOW edit=%p focus=%p fg=%p act=%p grab=%d", edit_, GetFocus(),
               fg, GetActiveWindow(), foreground_ours ? 1 : 0);
    return true;
  }

  void HandleHide() { Hide(false); }

  void HandleSetText(const std::wstring* text) {
    if (edit_ && text) {
      SetWindowTextW(edit_, text->c_str());
    }
  }

  std::wstring* HandleCommit() { return new std::wstring(GetTextWide()); }

  void HandleRelayout() {
    if (!shown_ || !popup_) {
      return;
    }
    // parent_ 属 UI 线程，User32 跨线程调用内部封送，可直接取屏幕坐标。
    POINT origin{rect_x_, rect_y_};
    ClientToScreen(parent_, &origin);
    SetWindowPos(popup_, nullptr, origin.x, origin.y, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  }

  void HandleOwnerDeactivate() {
    if (!shown_) {
      return;
    }
    ImeDiagLog("OWNER_DEACT shown=1 fg=%p", GetForegroundWindow());
    FocusEngineWindow();
  }

  void Quit() {
    ImeDiagLog("INPUT_QUIT tid=%lu",
               static_cast<unsigned long>(GetCurrentThreadId()));
    shown_ = false;
    if (popup_ && IsWindow(popup_)) {
      DestroyWindow(popup_);
    }
    popup_ = nullptr;
    edit_ = nullptr;
    PostQuitMessage(0);
  }

  // message-only 命令窗的窗口过程：UI 线程的全部封送命令在此落地，
  // 与 popup 自身的 UI 消息分离，popup 被宿主销毁链连带销毁也不影响命令可达。
  static LRESULT CALLBACK CommandWndProc(HWND hwnd, UINT message,
                                         WPARAM wparam, LPARAM lparam) {
    InputThreadContext* self = reinterpret_cast<InputThreadContext*>(
        GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    switch (message) {
      case kCmdShow: {
        auto* args = reinterpret_cast<ShowArgs*>(wparam);
        const bool ok = self ? self->HandleShow(args) : false;
        delete args;
        return ok ? 1 : 0;
      }
      case kCmdHide:
        if (self) {
          self->HandleHide();
        }
        return 0;
      case kCmdSetText: {
        auto* text = reinterpret_cast<std::wstring*>(wparam);
        if (self) {
          self->HandleSetText(text);
        }
        delete text;
        return 0;
      }
      case kCmdCommit:
        return reinterpret_cast<LRESULT>(self ? self->HandleCommit()
                                              : new std::wstring());
      case kCmdRelayout:
        if (self) {
          self->HandleRelayout();
        }
        return 0;
      case kCmdOwnerDeactivate:
        if (self) {
          self->HandleOwnerDeactivate();
        }
        return 0;
      case kCmdQuit:
        if (self) {
          self->Quit();
        }
        return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }

  static LRESULT CALLBACK PopupWndProc(HWND hwnd, UINT message,
                                       WPARAM wparam, LPARAM lparam) {
    InputThreadContext* self = reinterpret_cast<InputThreadContext*>(
        GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    switch (message) {
      case WM_ERASEBKGND:
        // 圆角区域内 EDIT 铺满，四角露出的 popup 自身用底色填充，避免黑角。
        if (self && self->bg_brush_) {
          RECT rc;
          GetClientRect(hwnd, &rc);
          FillRect(reinterpret_cast<HDC>(wparam), &rc, self->bg_brush_);
          return 1;
        }
        break;

      case WM_CTLCOLOREDIT:
        if (self) {
          HBRUSH brush = self->HandleCtlColor(
              reinterpret_cast<HDC>(wparam), reinterpret_cast<HWND>(lparam));
          if (brush) {
            return reinterpret_cast<LRESULT>(brush);
          }
        }
        break;

      case WM_SIZE:
        if (self && self->edit_ && self->edit_h_ > 0) {
          const int pw = static_cast<int>(LOWORD(lparam));
          const int ph = static_cast<int>(HIWORD(lparam));
          MoveWindow(self->edit_, 0, (ph - self->edit_h_) / 2, pw,
                     self->edit_h_, TRUE);
        }
        return 0;

      case WM_ACTIVATE:
        // WS_EX_NOACTIVATE 的 popup 理论上永不被激活；若日志出现 state!=0，
        // 说明 owner 失活(other=popup)并非瞬态——焦点/激活层级会随之改写。
        if (self) {
          ImeDiagLog("POPUP_ACT state=%u other=%p fg=%p owner_act=%p",
                     LOWORD(wparam), reinterpret_cast<void*>(lparam),
                     GetForegroundWindow(),
                     self->parent_ ? GetActiveWindow() : nullptr);
        }
        break;

      case WM_SETFOCUS:
        // 焦点不变量：shown 期间键盘焦点只能在 EDIT，绝不停留在 popup 容器。
        // 鼠标点到 EDIT 之外的留白时默认处理会把焦点设给 popup，立即还给
        // EDIT，使「焦点离开 EDIT 到同进程窗口」这一 TSF 半初始化前置状态
        // 无法存在。
        if (self && self->shown_ && self->edit_) {
          ImeDiagLog("POPUP_GOTFOCUS redirect->edit focus=%p", GetFocus());
          SetFocus(self->edit_);
        }
        break;

      case WM_KEYDOWN:
      case WM_SYSKEYDOWN:
        // 取证：键消息若落在 popup 容器而非 EDIT，会在此出现而 EDIT 的 KEY 缺失。
        ImeDiagLog("POPUP_KEY vk=%02lx sys=%d focus=%p",
                   static_cast<unsigned long>(wparam),
                   message == WM_SYSKEYDOWN ? 1 : 0, GetFocus());
        break;

      case WM_MOUSEACTIVATE:
        // 三种点击来源都必须由我们显式主导焦点转移：
        //  - 其他应用持前台：AttachThreadInput 后 SetForegroundWindow(owner) 再
        //    SetFocus(EDIT)，否则前台锁使焦点切换不落地，EDIT 有键盘焦点而前台
        //    仍是他人，TSF 不建活文档。
        //  - owner 主窗持前台（用户刚点过输入框外的 Flutter 区域）：必须显式
        //    SetFocus(EDIT)，靠 WM_LBUTTONDOWN 默认处理被动获焦会建出半初始化
        //    TSF 文档（实测此后搜狗字母直通、候选窗不弹且不可恢复）。
        //  - popup 自己持前台：同样补一次 SetFocus，幂等。
        if (self) {
          HWND fg = GetForegroundWindow();
          wchar_t fg_class[64] = {};
          if (fg) {
            GetClassNameW(fg, fg_class, _countof(fg_class));
          }
          ImeDiagLog("MOUSEACT shown=%d fg=%p act=%p fgcls=%ls",
                     self->shown_ ? 1 : 0, fg, GetActiveWindow(), fg_class);
        }
        if (self && self->shown_) {
          HWND owner = GetWindow(hwnd, GW_OWNER);
          HWND fg = GetForegroundWindow();
          const DWORD fg_tid =
              fg ? GetWindowThreadProcessId(fg, nullptr) : 0;
          const DWORD cur_tid = GetCurrentThreadId();
          const bool local_return = (fg == owner || fg == hwnd);
          const bool external =
              owner != nullptr && !local_return && fg_tid != 0 &&
              fg_tid != cur_tid;
          bool attached = false;
          if (external) {
            attached = AttachThreadInput(cur_tid, fg_tid, TRUE) != FALSE;
            SetForegroundWindow(owner);
          }
          if (self->edit_ && GetFocus() != self->edit_ &&
              (local_return || external)) {
            SetFocus(self->edit_);
          }
          if (attached) {
            AttachThreadInput(cur_tid, fg_tid, FALSE);
          }
        }
        return MA_NOACTIVATE;

      case WM_NCDESTROY:
        // Quit 主动销毁与 owner 销毁链都会到这：清句柄，析构 IsWindow 不再触碰。
        if (self) {
          self->popup_ = nullptr;
          self->edit_ = nullptr;
        }
        break;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }

  static LRESULT CALLBACK EditWndProc(HWND hwnd, UINT message,
                                      WPARAM wparam, LPARAM lparam) {
    // EDIT 是 popup 的子窗口，经 GetParent 取 popup 的 USERDATA 找回上下文。
    InputThreadContext* self = reinterpret_cast<InputThreadContext*>(
        GetWindowLongPtrW(GetParent(hwnd), GWLP_USERDATA));

    switch (message) {
      case WM_GETDLGCODE:
        return DLGC_WANTALLKEYS;

      case WM_CHAR:
        // 全量字符事件：WM_KEYDOWN 在而 WM_CHAR 不在 = 键被上游（TSF/IME）吞走。
        ImeDiagLog("CHAR ch=%04lx", static_cast<unsigned long>(wparam));
        // TranslateMessage 在派发 WM_KEYDOWN 之前就已把回车译为 WM_CHAR('\r')
        // 入队，KEYDOWN 里 return 0 拦不住；单行 EDIT 默认过程收到 '\r' 会响
        // 错误提示。发送已在 WM_KEYDOWN 处理，这里把回车字符吞掉消音。
        if (wparam == VK_RETURN) {
          return 0;
        }
        // Ctrl+A 已在 WM_KEYDOWN 处理为全选；TranslateMessage 仍会把 ^A 译为
        // WM_CHAR(0x01) 入队，RichEdit 默认过程对不认识的控制字符只响错误音。
        if (wparam == 0x01) {
          return 0;
        }
        break;

      case WM_SETFOCUS: {
        // 先让 EDIT 默认过程处理（它在此期间同步发出 WM_IME_SETCONTEXT）。
        const LRESULT focus_result = CallWindowProcW(
            self ? self->original_edit_proc_ : DefWindowProcW, hwnd, message,
            wparam, lparam);
        if (self) {
          self->has_focus_ = true;
          InvalidateRect(hwnd, nullptr, TRUE);
          ImeDiagLog("EDIT_SETFOCUS edit=%p", hwnd);
          ImeDiagLogWnd("setfocus_from", reinterpret_cast<HWND>(lparam));
        }
        return focus_result;
      }

      case WM_KILLFOCUS:
        if (self) {
          self->has_focus_ = false;
          InvalidateRect(hwnd, nullptr, TRUE);
        }
        // wParam 为即将获得焦点的窗口：焦点被系统抢回引擎窗口的抖动靠此条定位。
        ImeDiagLog("EDIT_KILLFOCUS edit=%p to=%p", hwnd,
                   reinterpret_cast<void*>(wparam));
        ImeDiagLogWnd("killfocus_to", reinterpret_cast<HWND>(wparam));
        break;

      case WM_INPUTLANGCHANGE:
        // 纯取证：输入线程有独立 TSF，不再做任何 reattach/复位动作。
        // wParam 是字符集，lParam 是新 HKL（0x08040804=搜狗）。
        ImeDiagLog("LANGCHANGE charset=%lu hkl=%08lx",
                   static_cast<unsigned long>(wparam),
                   static_cast<unsigned long>(lparam));
        break;

      case WM_IME_SETCONTEXT:
        // wParam=激活/失活，lParam=UI 能力位。失焦时 HIDE 标志紧跟 KILLFOCUS，
        // 是焦点回抢时序的关键证据。记录后仍交 EDIT 默认过程处理。
        ImeDiagLog("IME_SETCONTEXT active=%lu flags=%08lx",
                   static_cast<unsigned long>(wparam),
                   static_cast<unsigned long>(lparam));
        break;

      case WM_IME_STARTCOMPOSITION:
        // 正常组字每段一条：它出现即证明 IME 在吞键，与 DIRECT_KEY 互斥。
        ImeDiagLog("COMP_START");
        break;

      case WM_IME_ENDCOMPOSITION:
        ImeDiagLog("COMP_END");
        break;

      case WM_IME_NOTIFY:
        // 失效态指纹：按键不产生 STARTCOMPOSITION，只每键一条
        // IMN_SETCOMPOSITIONWINDOW(0x000B) 通知，候选窗永不弹。
        ImeDiagLog("IME_NOTIFY cmd=%04lx",
                   static_cast<unsigned long>(wparam));
        break;

      case WM_KEYDOWN:
        // 全量键事件取证：ctrl/menu/alt 状态与本线程键盘布局一并记录。
        ImeDiagLog(
            "KEY vk=%02lx ctrl=%d menu=%d focus=%p fg=%p act=%p hkl=%08lx",
            static_cast<unsigned long>(wparam),
            (GetKeyState(VK_CONTROL) & 0x8000) ? 1 : 0,
            (GetKeyState(VK_MENU) & 0x8000) ? 1 : 0, GetFocus(),
            GetForegroundWindow(), GetActiveWindow(),
            static_cast<unsigned long>(reinterpret_cast<ULONG_PTR>(
                GetKeyboardLayout(0))));
        if (self) {
          // 每次按键临时取窗口当前上下文查组字态，用完即释放（不持专属 HIMC）。
          HIMC ctx = ImmGetContext(hwnd);
          // RichEdit 5.0 在此宿主路径下不把 Ctrl+A 当全选命令（^A 的
          // WM_CHAR 0x01 落到默认过程只响错误提示音），显式发 EM_SETSEL。
          if (wparam == 'A' && (GetKeyState(VK_CONTROL) & 0x8000) &&
              !(GetKeyState(VK_MENU) & 0x8000)) {
            if (ctx) {
              ImmReleaseContext(hwnd, ctx);
            }
            SendMessageW(hwnd, EM_SETSEL, 0, static_cast<LPARAM>(-1));
            ImeDiagLog("KEY ctrl-a -> EM_SETSEL all");
            return 0;
          }
          if (wparam == VK_RETURN) {
            // 搜狗候选窗打开时 Enter 属于 IME（确认候选），不能当发送。
            const bool composing =
                ctx && ImmGetCompositionStringW(ctx, GCS_COMPSTR, nullptr, 0) > 0;
            if (!composing) {
              if (ctx) {
                ImmReleaseContext(hwnd, ctx);
              }
              self->Submit();
              return 0;
            }
          } else if (wparam == VK_ESCAPE) {
            if (ctx) {
              ImmReleaseContext(hwnd, ctx);
            }
            self->Hide(true);
            return 0;
          }
          // 直通指纹（不依赖 ImmGetOpenStatus——搜狗走 TSF 时该接口返回不可靠）：
          // 搜狗布局(HKL 低字 0x0804) + 无 Ctrl/Alt + 真实字母 vk(A-Z)。健康链路
          // 字母被 IME 吞走，控件只收得到 VK_PROCESSKEY(0xE5)；收到真实字母即
          // 毒化直通。独立线程架构下这里只做取证、不再做任何复位——若输入线程
          // 仍出现本指纹，说明线程隔离假设被证伪，需要换销毁重建线程的方案。
          const DWORD kbd_lang =
              static_cast<DWORD>(reinterpret_cast<ULONG_PTR>(
                  GetKeyboardLayout(0))) &
              0xFFFF;
          const bool ctrl_down = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
          const bool menu_down = (GetKeyState(VK_MENU) & 0x8000) != 0;
          const bool letter_key = wparam >= 'A' && wparam <= 'Z';
          if (letter_key && !ctrl_down && !menu_down && kbd_lang == 0x0804) {
            ImeDiagLog("DIRECT_KEY_DETECTED vk=%02lx hkl=%08lx",
                       static_cast<unsigned long>(wparam),
                       static_cast<unsigned long>(
                           reinterpret_cast<ULONG_PTR>(GetKeyboardLayout(0))));
          }
          if (ctx) {
            ImmReleaseContext(hwnd, ctx);
          }
        }
        break;

      case WM_PAINT: {
        const LRESULT painted =
            CallWindowProcW(self ? self->original_edit_proc_ : nullptr, hwnd,
                            message, wparam, lparam);
        // 占位只在「无焦点且空文本」时补绘：组字期间 EDIT 必有焦点，hint 绝不
        // 可能盖住 IME composition；默认绘制已 EndPaint，故用 GetDCEx 取可见区。
        const bool draw_hint = self && !self->has_focus_ &&
                               GetWindowTextLengthW(hwnd) == 0 &&
                               !self->hint_.empty();
        if (draw_hint) {
          HDC dc = GetDCEx(hwnd, nullptr, DCX_CACHE);
          if (dc) {
            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, self->hint_color_);
            HFONT old_font = nullptr;
            if (self->font_) {
              old_font = static_cast<HFONT>(SelectObject(dc, self->font_));
            }
            RECT rect;
            GetClientRect(hwnd, &rect);
            rect.left += self->pad_x_px_;
            DrawTextW(dc, self->hint_.c_str(), -1, &rect,
                      DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
            if (old_font) {
              SelectObject(dc, old_font);
            }
            ::ReleaseDC(hwnd, dc);
          }
        }
        return painted;
      }

      case WM_NCDESTROY:
        if (self) {
          SetWindowLongPtrW(hwnd, GWLP_WNDPROC,
                            reinterpret_cast<LONG_PTR>(self->original_edit_proc_));
        }
        break;
    }

    return CallWindowProcW(self ? self->original_edit_proc_ : DefWindowProcW,
                           hwnd, message, wparam, lparam);
  }

 private:
  void ApplyEditStyle() {
    if (!edit_) {
      return;
    }
    SendMessageW(edit_, EM_EXLIMITTEXT, 0, kMaxChars);
    // RichEdit 不发 WM_CTLCOLOREDIT：底色与文字色走专用消息。
    SendMessageW(edit_, EM_SETBKGNDCOLOR, 0, static_cast<LPARAM>(bg_color_));
    CHARFORMAT2W cf{};
    cf.cbSize = sizeof(cf);
    cf.dwMask = CFM_COLOR;
    cf.dwEffects = 0;  // 清 CFE_AUTOCOLOR，crTextColor 才生效
    cf.crTextColor = text_color_;
    SendMessageW(edit_, EM_SETCHARFORMAT, SCF_ALL,
                 reinterpret_cast<LPARAM>(&cf));
    if (font_) {
      SendMessageW(edit_, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
    }
    SendMessageW(edit_, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN,
                 MAKELPARAM(pad_x_px_, pad_x_px_));
  }

  void LayoutPopup(int x, int y, int w, int h) {
    rect_x_ = x;
    rect_y_ = y;
    rect_w_ = w;
    rect_h_ = h;
    POINT origin{x, y};
    ClientToScreen(parent_, &origin);
    MoveWindow(popup_, origin.x, origin.y, w, h, FALSE);
    ApplyRegion(w, h);
    LayoutEdit(h);
  }

  void LayoutEdit(int popup_h) {
    if (!edit_ || !font_ || popup_h <= 0) {
      return;
    }
    HDC dc = ::GetDC(edit_);
    if (!dc) {
      return;
    }
    HFONT old = static_cast<HFONT>(::SelectObject(dc, font_));
    TEXTMETRICW tm{};
    GetTextMetricsW(dc, &tm);
    ::SelectObject(dc, old);
    ::ReleaseDC(edit_, dc);
    // EDIT 高度取整行高（含 descent），垂直居中放进 popup；上下边带由
    // popup 的 WM_ERASEBKGND 用底色填充。
    edit_h_ = static_cast<int>(tm.tmHeight) + 2;
    if (edit_h_ > popup_h) {
      edit_h_ = popup_h;
    }
    const int ey = (popup_h - edit_h_) / 2;
    RECT rc;
    GetClientRect(popup_, &rc);
    MoveWindow(edit_, 0, ey, rc.right - rc.left, edit_h_, FALSE);
  }

  void ApplyRegion(int width, int height) {
    if (radius_px_ <= 0) {
      SetWindowRgn(popup_, nullptr, TRUE);
      return;
    }
    // CreateRoundRectRgn 的角椭圆参数是半径的两倍；SetWindowRgn 后区域归系统。
    HRGN region = CreateRoundRectRgn(0, 0, width + 1, height + 1,
                                     radius_px_ * 2, radius_px_ * 2);
    SetWindowRgn(popup_, region, TRUE);
  }

  HBRUSH HandleCtlColor(HDC dc, HWND child) {
    if (child != edit_ || !bg_brush_) {
      return nullptr;
    }
    SetTextColor(dc, text_color_);
    SetBkColor(dc, bg_color_);
    return bg_brush_;
  }

  std::wstring GetTextWide() const {
    if (!edit_) {
      return {};
    }
    const int len = GetWindowTextLengthW(edit_);
    if (len <= 0) {
      return {};
    }
    std::wstring wide(static_cast<size_t>(len), L'\0');
    GetWindowTextW(edit_, wide.data(), len + 1);
    return wide;
  }

  // 把键盘焦点还给 UI 线程的引擎窗口：跨线程 SetFocus 必须先
  // AttachThreadInput 绑定两个线程的输入队列。
  void FocusEngineWindow() {
    if (!engine_window_ || !IsWindow(engine_window_)) {
      return;
    }
    const DWORD ui_tid =
        GetWindowThreadProcessId(engine_window_, nullptr);
    const DWORD cur_tid = GetCurrentThreadId();
    const bool attached =
        ui_tid != cur_tid && AttachThreadInput(cur_tid, ui_tid, TRUE) != FALSE;
    SetFocus(engine_window_);
    if (attached) {
      AttachThreadInput(cur_tid, ui_tid, FALSE);
    }
  }

  void Hide(bool notify_dart) {
    if (!shown_) {
      return;
    }
    shown_ = false;
    ImeDiagLog("HIDE notify=%d", notify_dart ? 1 : 0);
    if (popup_) {
      ShowWindow(popup_, SW_HIDE);
    }
    FocusEngineWindow();
    if (notify_dart) {
      PostMessageW(callback_hwnd_, kCbClosed, 0, 0);
    }
  }

  void Submit() {
    std::string* utf8 = new std::string(WideToUtf8(GetTextWide()));
    // 只 Post 不 Send：输入线程绝不同步等待 UI 线程，杜绝跨线程死锁环。
    PostMessageW(callback_hwnd_, kCbSubmit,
                 reinterpret_cast<WPARAM>(utf8), 0);
  }

  HWND parent_;
  HWND engine_window_;
  HWND callback_hwnd_;
  HWND cmd_hwnd_ = nullptr;
  HWND popup_ = nullptr;
  HWND edit_ = nullptr;
  WNDPROC original_edit_proc_ = nullptr;

  bool shown_ = false;
  bool has_focus_ = false;
  // popup 目标矩形（宿主客户区物理像素坐标），供 HandleRelayout 重定位。
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
};

void RegisterPopupClass() {
  WNDCLASSW wc{};
  wc.lpfnWndProc = &InputThreadContext::PopupWndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kPopupClass;
  RegisterClassW(&wc);  // 重复注册返回 0/ERROR_CLASS_ALREADY_EXISTS，忽略
}

void RegisterInputCmdClass() {
  WNDCLASSW wc{};
  wc.lpfnWndProc = &InputThreadContext::CommandWndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kInputCmdClass;
  RegisterClassW(&wc);  // 重复注册忽略
}

void RegisterCallbackClass() {
  WNDCLASSW wc{};
  wc.lpfnWndProc = &NativeEditHost::CallbackWndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kCallbackClass;
  RegisterClassW(&wc);  // 重复注册忽略
}

}  // namespace

NativeEditHost::NativeEditHost(HWND parent, HWND engine_window,
                               flutter::BinaryMessenger* messenger)
    : parent_(parent), engine_window_(engine_window) {
  channel_ = std::make_unique<flutter::MethodChannel<>>(
      messenger, "simple_live/native_edit",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<>& call,
             std::unique_ptr<flutter::MethodResult<>> result) {
        HandleMethodCall(call, std::move(result));
      });

  // UI 线程 message-only 回调窗：输入线程 Post 回来的 submit/closed 在此
  // 落地，保证 MethodChannel InvokeMethod 始终在 messenger 所属线程执行。
  RegisterCallbackClass();
  callback_hwnd_ = CreateWindowExW(0, kCallbackClass, L"", 0, 0, 0, 0, 0,
                                   HWND_MESSAGE, nullptr,
                                   GetModuleHandleW(nullptr), nullptr);
  if (callback_hwnd_) {
    SetWindowLongPtrW(callback_hwnd_, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(this));
  } else {
    ImeDiagLog("HOST_CALLBACK_CREATE_FAIL err=%lu", GetLastError());
  }

  // 自宿主：owner 移动/激活/销毁由 subclass 自行处理；WM_NCDESTROY 时
  // delete this，调用方不持有指针。父窗无效时挂不上，subclass_id_ 留 0。
  subclass_id_ = SetWindowSubclass(parent_, OwnerSubclassProc, kOwnerSubclassId,
                                   reinterpret_cast<DWORD_PTR>(this));
  ImeDiagLog("HOST_CREATE host=%p parent=%p engine=%p callback=%p subclass=%llu",
             this, parent_, engine_window_, callback_hwnd_,
             static_cast<unsigned long long>(subclass_id_));
}

NativeEditHost::~NativeEditHost() {
  ImeDiagLog("HOST_DESTROY host=%p", this);
  TeardownInputThread();
  // 若析构不经由 OwnerSubclassProc 的 WM_NCDESTROY（例如显式 delete），
  // 此处补拆 subclass；已经拆过的路径会把 subclass_id_ 清 0。
  if (subclass_id_ != 0 && parent_ && IsWindow(parent_)) {
    RemoveWindowSubclass(parent_, OwnerSubclassProc, subclass_id_);
    subclass_id_ = 0;
  }
  if (callback_hwnd_ && IsWindow(callback_hwnd_)) {
    DestroyWindow(callback_hwnd_);
  }
  callback_hwnd_ = nullptr;
}

// static
DWORD WINAPI NativeEditHost::InputThreadMain(LPVOID param) {
  ThreadStartup* startup = static_cast<ThreadStartup*>(param);

  const HRESULT init_hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const bool need_uninit = SUCCEEDED(init_hr);
  if (FAILED(init_hr)) {
    ImeDiagLog("INPUT_THREAD_COINIT_FAIL hr=0x%08lx",
               static_cast<unsigned long>(init_hr));
  }

  // 显式激活本线程自己的 TSF client：拿到与 UI 线程独立的 ITfThreadMgr
  // 与搜狗 TIP 实例，这是线程隔离毒化的关键。
  ITfThreadMgr* thread_mgr = nullptr;
  TfClientId tf_client_id = 0;
  const HRESULT tm_hr = CoCreateInstance(
      CLSID_TF_ThreadMgr, nullptr, CLSCTX_INPROC_SERVER, IID_ITfThreadMgr,
      reinterpret_cast<void**>(&thread_mgr));
  if (SUCCEEDED(tm_hr) && thread_mgr) {
    const HRESULT act_hr = thread_mgr->Activate(&tf_client_id);
    ImeDiagLog("INPUT_THREAD_TSF activate=0x%08lx tid=%lu",
               static_cast<unsigned long>(act_hr),
               static_cast<unsigned long>(GetCurrentThreadId()));
  } else {
    ImeDiagLog("INPUT_THREAD_TSF_FAIL hr=0x%08lx",
               static_cast<unsigned long>(tm_hr));
  }

  auto* context = new InputThreadContext(startup->parent,
                                         startup->engine_window,
                                         startup->callback_hwnd);
  const bool ok = context->Initialize();
  *startup->cmd_out = ok ? context->cmd_hwnd() : nullptr;
  SetEvent(startup->ready);

  if (ok) {
    MSG msg;
    // TranslateMessage 不能省：WM_CHAR（含被吞毒化键的对照取证）由它生成。
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
  }
  delete context;

  if (thread_mgr) {
    thread_mgr->Deactivate();
    thread_mgr->Release();
  }
  if (need_uninit) {
    CoUninitialize();
  }
  ImeDiagLog("INPUT_THREAD_END tid=%lu",
             static_cast<unsigned long>(GetCurrentThreadId()));
  return 0;
}

bool NativeEditHost::EnsureInputThread() {
  if (thread_) {
    return input_cmd_ != nullptr;
  }
  ready_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!ready_event_) {
    ImeDiagLog("HOST_READY_EVENT_FAIL err=%lu", GetLastError());
    return false;
  }
  ThreadStartup startup{parent_, engine_window_, callback_hwnd_, ready_event_,
                        &input_cmd_};
  thread_ = CreateThread(nullptr, 0, &InputThreadMain, &startup, 0,
                         &input_tid_);
  if (!thread_) {
    ImeDiagLog("HOST_CREATE_THREAD_FAIL err=%lu", GetLastError());
    CloseHandle(ready_event_);
    ready_event_ = nullptr;
    return false;
  }
  // 栈上 startup 以事件同步：输入线程置位 popup 句柄并 SetEvent 后才返回。
  WaitForSingleObject(ready_event_, INFINITE);
  CloseHandle(ready_event_);
  ready_event_ = nullptr;

  if (!input_cmd_) {
    // 初始化失败：输入线程会自行走完清理并退出，这里回收句柄。
    WaitForSingleObject(thread_, INFINITE);
    CloseHandle(thread_);
    thread_ = nullptr;
    input_tid_ = 0;
    return false;
  }
  ImeDiagLog("HOST_THREAD_READY tid=%lu cmd=%p",
             static_cast<unsigned long>(input_tid_), input_cmd_);
  return true;
}

void NativeEditHost::TeardownInputThread() {
  if (!thread_) {
    return;
  }
  // 同步 quit：命令窗与线程同寿、无 owner，不会被宿主销毁链连带销毁，故
  // quit 永远可达。输入线程销毁 popup、PostQuitMessage 退出消息循环后本调用
  // 才返回，保证 delete this 前输入线程已不再触碰宿主对象与回调窗。
  if (input_cmd_ && IsWindow(input_cmd_)) {
    SendMessageW(input_cmd_, kCmdQuit, 0, 0);
  }
  WaitForSingleObject(thread_, INFINITE);
  CloseHandle(thread_);
  thread_ = nullptr;
  input_cmd_ = nullptr;
  input_tid_ = 0;
  if (ready_event_) {
    CloseHandle(ready_event_);
    ready_event_ = nullptr;
  }
}

void NativeEditHost::HandleMethodCall(
    const flutter::MethodCall<>& call,
    std::unique_ptr<flutter::MethodResult<>> result) {
  const std::string& name = call.method_name();
  if (name == "show") {
    const auto* args =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (!args) {
      result->Error("bad_args", "show requires a map");
      return;
    }
    if (!EnsureInputThread()) {
      result->Error("thread_failed", "input thread start failed");
      return;
    }
    auto at = [&](const char* key) -> const flutter::EncodableValue* {
      auto it = args->find(flutter::EncodableValue(key));
      return it == args->end() ? nullptr : &it->second;
    };
    auto str_at = [&](const char* key) -> std::string {
      const flutter::EncodableValue* v = at(key);
      if (const auto* s = v ? std::get_if<std::string>(v) : nullptr) {
        return *s;
      }
      return {};
    };

    auto* show = new ShowArgs();
    show->x = at("x") ? AsInt(*at("x")) : 0;
    show->y = at("y") ? AsInt(*at("y")) : 0;
    show->w = at("w") ? AsInt(*at("w")) : 0;
    show->h = at("h") ? AsInt(*at("h")) : 0;
    show->radius = at("radius") ? AsInt(*at("radius")) : 0;
    show->pad_x = at("padX") ? AsInt(*at("padX")) : 0;
    show->font_px = at("fontSize") ? AsDouble(*at("fontSize")) : 16.0;
    show->bg = at("bg") ? RgbFromArgb(AsUInt32(*at("bg")))
                        : RGB(255, 255, 255);
    show->text_color = at("textColor")
                           ? RgbFromArgb(AsUInt32(*at("textColor")))
                           : RGB(0, 0, 0);
    show->hint_color = at("hintColor")
                           ? RgbFromArgb(AsUInt32(*at("hintColor")))
                           : RGB(128, 128, 128);
    show->hint_text = Utf8ToWide(str_at("hint"));
    show->initial_text = Utf8ToWide(str_at("text"));

    // 所有权随消息转移：输入线程处理完必定 delete，任何返回路径都不泄漏。
    const LRESULT ok = SendMessageW(input_cmd_, kCmdShow,
                                    reinterpret_cast<WPARAM>(show), 0);
    if (ok) {
      result->Success();
    } else {
      result->Error("create_failed", "native popup show failed");
    }
  } else if (name == "hide") {
    if (input_cmd_) {
      PostMessageW(input_cmd_, kCmdHide, 0, 0);
    }
    result->Success();
  } else if (name == "setText") {
    if (const auto* text = std::get_if<std::string>(call.arguments())) {
      if (input_cmd_) {
        auto* wide = new std::wstring(Utf8ToWide(*text));
        PostMessageW(input_cmd_, kCmdSetText,
                     reinterpret_cast<WPARAM>(wide), 0);
      }
    }
    result->Success();
  } else if (name == "commit") {
    if (!input_cmd_) {
      result->Success(flutter::EncodableValue(std::string()));
      return;
    }
    // 同步往返保留请求-应答语义：输入线程在自己的消息循环里立即处理，
    // 且它对 UI 线程只 Post 不 Send，不存在双向等待死锁。
    auto* wide = reinterpret_cast<std::wstring*>(
        SendMessageW(input_cmd_, kCmdCommit, 0, 0));
    std::string text;
    if (wide) {
      text = WideToUtf8(*wide);
      delete wide;
    }
    result->Success(flutter::EncodableValue(text));
  } else {
    result->NotImplemented();
  }
}

// static
LRESULT CALLBACK NativeEditHost::CallbackWndProc(HWND hwnd, UINT message,
                                                 WPARAM wparam,
                                                 LPARAM lparam) {
  NativeEditHost* self = reinterpret_cast<NativeEditHost*>(
      GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (message == kCbSubmit) {
    auto* text = reinterpret_cast<std::string*>(wparam);
    if (self && self->channel_ && text) {
      self->channel_->InvokeMethod(
          "submit", std::make_unique<flutter::EncodableValue>(*text));
    }
    delete text;
    return 0;
  }
  if (message == kCbClosed) {
    if (self && self->channel_) {
      self->channel_->InvokeMethod(
          "closed", std::make_unique<flutter::EncodableValue>());
    }
    return 0;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

// static
LRESULT CALLBACK NativeEditHost::OwnerSubclassProc(
    HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam,
    UINT_PTR subclass_id, DWORD_PTR ref_data) {
  NativeEditHost* self = reinterpret_cast<NativeEditHost*>(ref_data);
  switch (message) {
    case WM_MOVE:
    case WM_SIZE:
      // popup 是屏幕坐标的顶层窗口，宿主移动/缩放时跟随原客户区锚点。
      // 缩放的精确位置另由 Dart didChangeMetrics 重发 show 修正。
      if (self && self->input_cmd_) {
        PostMessageW(self->input_cmd_, kCmdRelayout, 0, 0);
      }
      break;

    case WM_ACTIVATE:
      // 失活前把键盘焦点从常驻 popup 的 EDIT 撤回引擎窗口：否则线程重新被
      // 激活时系统会把焦点（连同前台窗口）恢复给 WS_EX_NOACTIVATE 的 popup，
      // 主窗标题栏持续灰显，点击只用于激活而送不到 Flutter。shown 状态在
      // 输入线程侧，命令统一发过去由其 no-op 判定。
      if (self) {
        ImeDiagLog("OWNER_ACT state=%u other=%p fg=%p act=%p",
                   LOWORD(wparam), reinterpret_cast<void*>(lparam),
                   GetForegroundWindow(), GetActiveWindow());
      }
      if (self && LOWORD(wparam) == WA_INACTIVE && self->input_cmd_) {
        // 仅当激活对端属于其他线程（真正切到别的应用）才撤回焦点。本 app
        // 窗口间点击会产生同毫秒 WA_ACTIVE→WA_INACTIVE 瞬态，对端仍是本
        // 线程窗口；此时撤焦点会与 EDIT 点击获焦打架。
        DWORD other_tid = 0;
        if (lparam) {
          other_tid = GetWindowThreadProcessId(
              reinterpret_cast<HWND>(lparam), nullptr);
        }
        if (other_tid != GetCurrentThreadId()) {
          SendMessageW(self->input_cmd_, kCmdOwnerDeactivate, 0, 0);
        }
      }
      break;

    case WM_NCDESTROY:
      // 按 Microsoft 子类示例：先 RemoveWindowSubclass（此时 hwnd 仍有效），
      // 再停输入线程、delete，最后把本条消息交给 DefSubclassProc。
      if (self) {
        RemoveWindowSubclass(hwnd, OwnerSubclassProc, self->subclass_id_);
        self->subclass_id_ = 0;
        self->TeardownInputThread();
        delete self;
      }
      break;
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}
