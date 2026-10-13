#include "native_edit_host.h"

#include <imm.h>

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>

namespace {

constexpr int kMaxChars = 200;
constexpr wchar_t kFontFace[] = L"Microsoft YaHei UI";

// 进程只有一个顶层窗口、一个 NativeEditHost；EDIT 子类过程靠它找回对象。
NativeEditHost* g_instance = nullptr;

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

COLORREF RgbFromArgb(int32_t value) {
  const auto v = static_cast<uint32_t>(value);
  return RGB(v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF);
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

}  // namespace

NativeEditHost::NativeEditHost(HWND parent, HWND engine_window,
                               flutter::BinaryMessenger* messenger)
    : parent_(parent), engine_window_(engine_window) {
  g_instance = this;
  bg_brush_ = CreateSolidBrush(bg_color_);
  channel_ = std::make_unique<flutter::MethodChannel<>>(
      messenger, "simple_live/native_edit",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<>& call,
             std::unique_ptr<flutter::MethodResult<>> result) {
        HandleMethodCall(call, std::move(result));
      });
}

NativeEditHost::~NativeEditHost() {
  if (edit_) {
    SetWindowLongPtrW(edit_, GWLP_WNDPROC,
                      reinterpret_cast<LONG_PTR>(original_edit_proc_));
    ImmAssociateContext(edit_, nullptr);
    DestroyWindow(edit_);
    edit_ = nullptr;
  }
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
  if (g_instance == this) {
    g_instance = nullptr;
  }
}

bool NativeEditHost::EnsureCreated() {
  if (edit_) {
    return true;
  }
  edit_ = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | ES_AUTOHSCROLL, 0, 0,
                          10, 10, parent_, nullptr, GetModuleHandleW(nullptr),
                          nullptr);
  if (!edit_) {
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
      at("bg") ? RgbFromArgb(AsInt(*at("bg"))) : RGB(255, 255, 255);
  const COLORREF new_text =
      at("textColor") ? RgbFromArgb(AsInt(*at("textColor"))) : RGB(0, 0, 0);
  const COLORREF new_hint =
      at("hintColor") ? RgbFromArgb(AsInt(*at("hintColor")))
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

  MoveWindow(edit_, x, y, w, h, FALSE);
  SendMessageW(edit_, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN,
               MAKELPARAM(pad_x_px_, pad_x_px_));
  ApplyRegion(w, h);
  SetWindowTextW(edit_, Utf8ToWide(str_at("text")).c_str());

  ShowWindow(edit_, SW_SHOWNOACTIVATE);
  shown_ = true;
  SetFocus(edit_);
}

void NativeEditHost::ApplyRegion(int width, int height) {
  if (radius_px_ <= 0) {
    SetWindowRgn(edit_, nullptr, TRUE);
    return;
  }
  // CreateRoundRectRgn 的角椭圆参数是半径的两倍；SetWindowRgn 后区域归系统。
  HRGN region = CreateRoundRectRgn(0, 0, width + 1, height + 1,
                                   radius_px_ * 2, radius_px_ * 2);
  SetWindowRgn(edit_, region, TRUE);
}

void NativeEditHost::Hide(bool notify_dart) {
  if (!shown_) {
    return;
  }
  shown_ = false;
  if (edit_) {
    ShowWindow(edit_, SW_HIDE);
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
  channel_->InvokeMethod("submit",
                         std::make_unique<flutter::EncodableValue>(GetText()));
}

void NativeEditHost::Refocus() {
  if (shown_ && edit_) {
    SetFocus(edit_);
  }
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
    if (edit_) {
      result->Success();
    } else {
      result->Error("create_failed", "CreateWindowExW(EDIT) failed");
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

LRESULT CALLBACK NativeEditHost::EditWndProc(HWND hwnd, UINT message,
                                             WPARAM wparam, LPARAM lparam) {
  NativeEditHost* self = g_instance;

  switch (message) {
    case WM_GETDLGCODE:
      return DLGC_WANTALLKEYS;

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
      // 默认绘制已 EndPaint、更新区被清空；GetDCEx 取窗口可见区做裁剪补绘。
      if (self && GetWindowTextLengthW(hwnd) == 0 && !self->hint_.empty()) {
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
          ReleaseDC(hwnd, dc);
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
