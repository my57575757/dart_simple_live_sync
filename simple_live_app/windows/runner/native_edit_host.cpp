#include "native_edit_host.h"

#include <commctrl.h>
#include <imm.h>

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>

// SetWindowSubclass 在 comctl32；CMake 未显式链接，这里补齐。
#pragma comment(lib, "comctl32.lib")

namespace {

constexpr int kMaxChars = 200;
constexpr wchar_t kFontFace[] = L"Microsoft YaHei UI";
constexpr wchar_t kPopupClass[] = L"SimpleLiveNativeEditPopup";
// SetWindowSubclass 的 uIdSubclass；返回值恒为 1，与 subclass_id_ 对齐。
constexpr UINT_PTR kOwnerSubclassId = 1;

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

void RegisterPopupClass() {
  WNDCLASSW wc{};
  wc.lpfnWndProc = &NativeEditHost::PopupWndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kPopupClass;
  RegisterClassW(&wc);  // 重复注册返回 0/ERROR_CLASS_ALREADY_EXISTS，忽略
}

}  // namespace

NativeEditHost::NativeEditHost(HWND parent, HWND engine_window,
                               flutter::BinaryMessenger* messenger)
    : parent_(parent), engine_window_(engine_window) {
  bg_brush_ = CreateSolidBrush(bg_color_);
  channel_ = std::make_unique<flutter::MethodChannel<>>(
      messenger, "simple_live/native_edit",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<>& call,
             std::unique_ptr<flutter::MethodResult<>> result) {
        HandleMethodCall(call, std::move(result));
      });
  // 自宿主：owner 移动/激活/销毁由 subclass 自行处理；WM_NCDESTROY 时
  // delete this，调用方不持有指针。父窗无效时挂不上，subclass_id_ 留 0。
  subclass_id_ = SetWindowSubclass(parent_, OwnerSubclassProc, kOwnerSubclassId,
                                   reinterpret_cast<DWORD_PTR>(this));
}

NativeEditHost::~NativeEditHost() {
  // 若析构不是经由 OwnerSubclassProc 的 WM_NCDESTROY 触发（例如显式 delete），
  // 此处补拆 subclass；已经拆过的路径会把 subclass_id_ 清 0。
  if (subclass_id_ != 0 && parent_ && IsWindow(parent_)) {
    RemoveWindowSubclass(parent_, OwnerSubclassProc, subclass_id_);
    subclass_id_ = 0;
  }
  // owner 销毁时系统会先销毁 owned popup（句柄可能已失效），IsWindow 防踩。
  if (edit_ && IsWindow(edit_)) {
    SetWindowLongPtrW(edit_, GWLP_WNDPROC,
                      reinterpret_cast<LONG_PTR>(original_edit_proc_));
    ImmAssociateContext(edit_, nullptr);
  }
  if (popup_ && IsWindow(popup_)) {
    // 连带销毁其中的 EDIT。
    DestroyWindow(popup_);
  }
  popup_ = nullptr;
  edit_ = nullptr;
  if (himc_) {
    ImmDestroyContext(himc_);
    himc_ = nullptr;
  }
  if (bg_brush_) {
    DeleteObject(bg_brush_);
    bg_brush_ = nullptr;
  }
  if (font_) {
    DeleteObject(font_);
    font_ = nullptr;
  }
}

bool NativeEditHost::EnsureCreated() {
  if (popup_) {
    return true;
  }
  RegisterPopupClass();
  // WS_EX_NOACTIVATE：点击/显示不抢占主窗口激活态；WS_EX_TOOLWINDOW：
  // 不进任务栏与 Alt-Tab。owner 为主窗口，popup 恒在其所有子窗口之上。
  popup_ = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, kPopupClass,
                           L"", WS_POPUP | WS_CLIPCHILDREN, 0, 0, 10, 10,
                           parent_, nullptr, GetModuleHandleW(nullptr),
                           nullptr);
  if (!popup_) {
    return false;
  }
  // 每窗一个 host：窗口过程经 GWLP_USERDATA 找回对象（取代进程单例）。
  SetWindowLongPtrW(popup_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  edit_ = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | ES_AUTOHSCROLL, 0, 0, 10,
                          10, popup_, nullptr, GetModuleHandleW(nullptr),
                          nullptr);
  if (!edit_) {
    DestroyWindow(popup_);
    popup_ = nullptr;
    return false;
  }
  original_edit_proc_ = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(
      edit_, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(&EditWndProc)));
  SendMessageW(edit_, EM_LIMITTEXT, kMaxChars, 0);

  // 专属 HIMC：与引擎窗口默认上下文隔离，这是绕开死桥的关键。
  himc_ = ImmCreateContext();
  if (himc_) {
    ImmAssociateContext(edit_, himc_);
    ImmSetOpenStatus(himc_, TRUE);
  }
  return true;
}

void NativeEditHost::LayoutPopup(int x, int y, int w, int h) {
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

void NativeEditHost::LayoutEdit(int popup_h) {
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

void NativeEditHost::Show(const flutter::EncodableMap& args) {
  if (!EnsureCreated()) {
    return;
  }
  auto at = [&](const char* key) -> const flutter::EncodableValue* {
    auto it = args.find(flutter::EncodableValue(key));
    return it == args.end() ? nullptr : &it->second;
  };
  auto str_at = [&](const char* key) -> std::string {
    const auto* v = at(key);
    if (const auto* s = v ? std::get_if<std::string>(v) : nullptr) {
      return *s;
    }
    return {};
  };

  const int x = at("x") ? AsInt(*at("x")) : 0;
  const int y = at("y") ? AsInt(*at("y")) : 0;
  const int w = at("w") ? AsInt(*at("w")) : 0;
  const int h = at("h") ? AsInt(*at("h")) : 0;
  const int radius = at("radius") ? AsInt(*at("radius")) : 0;
  const int pad_x = at("padX") ? AsInt(*at("padX")) : 0;
  const double font_px = at("fontSize") ? AsDouble(*at("fontSize")) : 16.0;
  const COLORREF new_bg =
      at("bg") ? RgbFromArgb(AsUInt32(*at("bg"))) : RGB(255, 255, 255);
  const COLORREF new_text =
      at("textColor") ? RgbFromArgb(AsUInt32(*at("textColor")))
                      : RGB(0, 0, 0);
  const COLORREF new_hint =
      at("hintColor") ? RgbFromArgb(AsUInt32(*at("hintColor")))
                      : RGB(128, 128, 128);
  hint_ = Utf8ToWide(str_at("hint"));

  if (new_bg != bg_color_ || !bg_brush_) {
    bg_color_ = new_bg;
    if (bg_brush_) {
      DeleteObject(bg_brush_);
    }
    bg_brush_ = CreateSolidBrush(bg_color_);
  }
  text_color_ = new_text;
  hint_color_ = new_hint;
  radius_px_ = radius;
  pad_x_px_ = pad_x;

  HFONT new_font =
      CreateFontW(-static_cast<int>(std::lround(font_px)), 0, 0, 0, FW_NORMAL,
                  FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                  CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                  DEFAULT_PITCH | FF_DONTCARE, kFontFace);
  if (new_font) {
    if (font_) {
      DeleteObject(font_);
    }
    font_ = new_font;
    SendMessageW(edit_, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
  }

  SendMessageW(edit_, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN,
               MAKELPARAM(pad_x_px_, pad_x_px_));
  LayoutPopup(x, y, w, h);
  // 文本只在「从隐藏态打开」时同步一次；relayout 会带着 shown_==true 重入，
  // 那时 SetWindowText 会清空用户正在输入的内容。发送后清空走 setText 通道。
  if (!shown_) {
    SetWindowTextW(edit_, Utf8ToWide(str_at("text")).c_str());
  }

  ShowWindow(popup_, SW_SHOWNOACTIVATE);
  // EDIT 是 WS_CHILD，创建后默认隐藏，必须随 popup 一起显示，否则容器是空壳。
  ShowWindow(edit_, SW_SHOWNOACTIVATE);
  // owned 窗口理论上恒在 owner 之上，显式再提一次以防被 DComp 表面压住。
  SetWindowPos(popup_, HWND_TOP, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  shown_ = true;
  SetFocus(edit_);
}

void NativeEditHost::ApplyRegion(int width, int height) {
  if (radius_px_ <= 0) {
    SetWindowRgn(popup_, nullptr, TRUE);
    return;
  }
  // CreateRoundRectRgn 的角椭圆参数是半径的两倍；SetWindowRgn 后区域归系统。
  HRGN region = CreateRoundRectRgn(0, 0, width + 1, height + 1,
                                   radius_px_ * 2, radius_px_ * 2);
  SetWindowRgn(popup_, region, TRUE);
}

void NativeEditHost::Hide(bool notify_dart) {
  if (!shown_) {
    return;
  }
  shown_ = false;
  if (popup_) {
    ShowWindow(popup_, SW_HIDE);
  }
  if (engine_window_) {
    SetFocus(engine_window_);
  }
  if (notify_dart) {
    channel_->InvokeMethod(
        "closed", std::make_unique<flutter::EncodableValue>());
  }
}

void NativeEditHost::SetText(const std::string& utf8) {
  if (edit_) {
    SetWindowTextW(edit_, Utf8ToWide(utf8).c_str());
  }
}

std::string NativeEditHost::GetText() const {
  if (!edit_) {
    return {};
  }
  const int len = GetWindowTextLengthW(edit_);
  if (len <= 0) {
    return {};
  }
  std::wstring wide(static_cast<size_t>(len), L'\0');
  GetWindowTextW(edit_, wide.data(), len + 1);
  return WideToUtf8(wide);
}

void NativeEditHost::Submit() {
  const std::string text = GetText();
  channel_->InvokeMethod(
      "submit", std::make_unique<flutter::EncodableValue>(text));
}

void NativeEditHost::OnOwnerMoved() {
  if (!shown_ || !popup_) {
    return;
  }
  POINT origin{rect_x_, rect_y_};
  ClientToScreen(parent_, &origin);
  SetWindowPos(popup_, nullptr, origin.x, origin.y, 0, 0,
               SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

HBRUSH NativeEditHost::HandleCtlColor(HDC dc, HWND child) {
  if (child != edit_ || !bg_brush_) {
    return nullptr;
  }
  SetTextColor(dc, text_color_);
  SetBkColor(dc, bg_color_);
  return bg_brush_;
}

void NativeEditHost::HandleMethodCall(
    const flutter::MethodCall<>& call,
    std::unique_ptr<flutter::MethodResult<>> result) {
  const std::string& name = call.method_name();
  if (name == "show") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (!args) {
      result->Error("bad_args", "show requires a map");
      return;
    }
    Show(*args);
    if (popup_) {
      result->Success();
    } else {
      result->Error("create_failed", "native popup create failed");
    }
  } else if (name == "hide") {
    Hide(false);
    result->Success();
  } else if (name == "setText") {
    if (const auto* text = std::get_if<std::string>(call.arguments())) {
      SetText(*text);
    }
    result->Success();
  } else if (name == "commit") {
    result->Success(flutter::EncodableValue(GetText()));
  } else {
    result->NotImplemented();
  }
}

LRESULT CALLBACK NativeEditHost::PopupWndProc(HWND hwnd, UINT message,
                                              WPARAM wparam, LPARAM lparam) {
  NativeEditHost* self = reinterpret_cast<NativeEditHost*>(
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

    case WM_MOUSEACTIVATE:
      // popup 常驻时用户从其他应用直接点输入框切回：WS_EX_NOACTIVATE 使系统
      // 不激活任何窗口，键盘消息仍去原前台应用，表现为点得中却输不进字。
      // 主动激活 owner 主窗（popup 自己仍不当前台，避免主窗标题灰显），
      // 随后点击消息到 EDIT，其默认处理正常取得键盘焦点。
      if (self && self->shown_) {
        HWND owner = GetWindow(hwnd, GW_OWNER);
        if (owner && GetForegroundWindow() != owner) {
          SetForegroundWindow(owner);
          if (self->edit_) {
            SetFocus(self->edit_);
          }
        }
      }
      return MA_NOACTIVATE;

    case WM_NCDESTROY:
      // 系统销毁 owned popup（owner 销毁链）时清句柄，析构 IsWindow 不再触碰。
      if (self) {
        self->popup_ = nullptr;
        self->edit_ = nullptr;
      }
      break;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

LRESULT CALLBACK NativeEditHost::EditWndProc(HWND hwnd, UINT message,
                                             WPARAM wparam, LPARAM lparam) {
  // EDIT 是 popup 的子窗口，经 GetParent 取 popup 的 USERDATA 找回 host。
  NativeEditHost* self = reinterpret_cast<NativeEditHost*>(
      GetWindowLongPtrW(GetParent(hwnd), GWLP_USERDATA));

  switch (message) {
    case WM_GETDLGCODE:
      return DLGC_WANTALLKEYS;

    case WM_CHAR:
      // TranslateMessage 在派发 WM_KEYDOWN 之前就已把回车译为 WM_CHAR('\r')
      // 入队，KEYDOWN 里 return 0 拦不住；单行 EDIT 默认过程收到 '\r' 会响一声
      // 错误提示。发送已在 WM_KEYDOWN 处理，这里把回车字符吞掉消音。
      if (wparam == VK_RETURN) {
        return 0;
      }
      break;

    case WM_SETFOCUS:
      if (self) {
        self->has_focus_ = true;
        InvalidateRect(hwnd, nullptr, TRUE);
      }
      break;

    case WM_KILLFOCUS:
      if (self) {
        self->has_focus_ = false;
        InvalidateRect(hwnd, nullptr, TRUE);
      }
      break;

    case WM_KEYDOWN:
      if (self) {
        if (wparam == VK_RETURN) {
          bool composing = false;
          if (self->himc_) {
            // 搜狗候选窗打开时 Enter 属于 IME（确认候选），不能当发送。
            composing = ImmGetCompositionStringW(self->himc_, GCS_COMPSTR,
                                                 nullptr, 0) > 0;
          }
          if (!composing) {
            self->Submit();
            return 0;
          }
        } else if (wparam == VK_ESCAPE) {
          self->Hide(true);
          return 0;
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

// static
LRESULT CALLBACK NativeEditHost::OwnerSubclassProc(HWND hwnd, UINT message,
                                                   WPARAM wparam, LPARAM lparam,
                                                   UINT_PTR subclass_id,
                                                   DWORD_PTR ref_data) {
  NativeEditHost* self = reinterpret_cast<NativeEditHost*>(ref_data);
  switch (message) {
    case WM_MOVE:
    case WM_SIZE:
      // popup 是屏幕坐标的顶层窗口，宿主移动/缩放时跟随原客户区锚点。
      // 缩放的精确位置另由 Dart didChangeMetrics 重发 show 修正。
      if (self) {
        self->OnOwnerMoved();
      }
      break;

    case WM_ACTIVATE:
      // 失活前把键盘焦点从常驻 popup 的 EDIT 撤回引擎窗口：否则线程重新被
      // 激活时系统会把焦点（连同前台窗口）恢复给 WS_EX_NOACTIVATE 的 popup，
      // 主窗标题栏持续灰显，点击只用于激活而送不到 Flutter（标签栏切不动、
      // 按钮点了没反应）。激活时不再 Refocus——那正是焦点被抢走的根源。
      if (self && LOWORD(wparam) == WA_INACTIVE && self->shown_ &&
          self->engine_window_) {
        SetFocus(self->engine_window_);
      }
      break;

    case WM_NCDESTROY:
      // 按 Microsoft 子类示例：先 RemoveWindowSubclass（此时 hwnd 仍有效）
      // 再 delete，最后把本条消息交给 DefSubclassProc。MethodChannel 析构
      // 不触碰 messenger；owned popup 多半已被系统先销毁，析构 IsWindow 防踩。
      if (self) {
        RemoveWindowSubclass(hwnd, OwnerSubclassProc, self->subclass_id_);
        self->subclass_id_ = 0;
        delete self;
      }
      break;
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}
