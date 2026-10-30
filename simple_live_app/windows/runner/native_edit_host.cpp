#include "native_edit_host.h"

#include <commctrl.h>
#include <imm.h>
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

namespace {

constexpr int kMaxChars = 200;
constexpr wchar_t kFontFace[] = L"Microsoft YaHei UI";
// 输入控件窗口类：用 RichEdit 5.0（msftedit.dll，RICHEDIT50W）而非 legacy EDIT。
// RichEdit 自带符合现代 TSF 的 edit context，不依赖 legacy EDIT 那套会被半
// 初始化毒化的 IMM32 文档桥（实测 EDIT 在切语言/跨窗后 TSF 文档无法恢复，
// 销毁重建也只在恰好穿过语言切换重评估时才可能成功），从架构上绕开毒化。
constexpr wchar_t kEditClass[] = L"RICHEDIT50W";

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
constexpr wchar_t kPopupClass[] = L"SimpleLiveNativeEditPopup";
// SetWindowSubclass 的 uIdSubclass；返回值恒为 1，与 subclass_id_ 对齐。
constexpr UINT_PTR kOwnerSubclassId = 1;

// WM_KEYDOWN 检出「直通指纹」（中文布局 + IME 打开态 + 真实字母 vk +
// comp 为空）后，跨消息循环一拍重建 EDIT 窗口（连同全新 HIMC）。
// TSF 文档绑在 EDIT 窗口生命周期上，实测焦点弹跳与重挂同一 HIMC 均不触发
// 文档重建，只有新窗口首次获焦时活动 TIP 为搜狗才会建出可用文档
// （见 RecreateEditWindow）。不做切语言/切窗时的预防性重建——健康路径上
// 反复销毁 TSF 文档本身就是毒化源；指纹零误判，代价仅是毒化瞬间那一个键。
constexpr UINT kMsgHealRecreate = WM_APP + 1;

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

// IME 故障常驻取证：跨进程切窗后搜狗字母直通、候选窗不弹是焦点/激活时序
// 竞态，事后无法复盘。关键事件落 %TEMP%\simple_live_ime.log，进程首次写时
// 截断重建（只留本进程），事件低频，无需轮转。内容全 ASCII，规避日志编码。
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

// 记一条 HIMC 三指标（打开态/转换模式/整句模式）+ 当前线程键盘布局。
// 故障态下三者全部看似正常（open=1、conv 含 NATIVE、hkl=08040804），
// 但 IME 已不吞键——用于与 DIRECT_KEY 指纹对照定性。
void ImeDiagImeState(const char* tag, HIMC himc) {
  DWORD open = 0;
  DWORD conv = 0;
  DWORD sentence = 0;
  if (himc) {
    open = ImmGetOpenStatus(himc) ? 1u : 0u;
    ImmGetConversionStatus(himc, &conv, &sentence);
  }
  ImeDiagLog("%s himc=%p open=%lu conv=%08lx sentence=%08lx hkl=%08lx", tag,
             himc, open, conv, sentence,
             static_cast<unsigned long>(reinterpret_cast<ULONG_PTR>(
                 GetKeyboardLayout(0))));
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
        cls[i] = wcls[i] < 0x80 ? static_cast<char>(wcls[i]) : '?';
      }
    }
    wnd_tid = GetWindowThreadProcessId(wnd, nullptr);
    owner = GetWindow(wnd, GW_OWNER);
    style = GetWindowLongPtrW(wnd, GWL_STYLE);
    visible = IsWindowVisible(wnd);
  }
  ImeDiagLog("WND tag=%s wnd=%p cls=%s tid=%lu owner=%p child=%d vis=%d", tag,
             wnd, cls, wnd_tid, owner,
             (style & WS_CHILD) ? 1 : 0, visible ? 1 : 0);
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
  ImeDiagLog("HOST_CREATE host=%p parent=%p engine=%p subclass=%llu", this,
             parent_, engine_window_,
             static_cast<unsigned long long>(subclass_id_));
}

NativeEditHost::~NativeEditHost() {
  ImeDiagLog("HOST_DESTROY host=%p", this);
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

void NativeEditHost::ApplyEditStyle() {
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
  edit_ = CreateEditControl(popup_, 0, 0, 10, 10);
  if (!edit_) {
    DestroyWindow(popup_);
    popup_ = nullptr;
    return false;
  }
  original_edit_proc_ = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(
      edit_, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(&EditWndProc)));
  ApplyEditStyle();

  // 刻意不 ImmCreateContext / ImmAssociateContext：给窗口强挂 legacy HIMC 会
  // 把 RichEdit 从其原生 TSF edit context 拖回 IMM32 兼容桥，而搜狗在该桥上
  // 有「英语布局获焦后框内切中文则永久直通」的毒化（EDIT/RichEdit 同构复现）。
  // 不关联任何 HIMC，让 RichEdit 走自带的现代 TSF 上下文。
  ImeDiagLog("ENSURE host=%p popup=%p edit=%p nativeTSF=1", this, popup_,
             edit_);
  return true;
}

void NativeEditHost::ReattachImeContext(const char* reason) {
  if (!himc_ || !edit_) {
    return;
  }
  // 实测（搜狗，跨进程切窗后）：HIMC 的打开态、转换模式、与 EDIT 的关联句柄
  // 全部正常，但 IME 不再吞键，字母直达 EDIT、候选窗不弹——TSF 把此窗口的
  // 文档焦点留在了半初始化状态。先解除再重新关联专属 HIMC，逼 IME 重走
  // activate/focus 流程，并补回打开态与中文转换位。EDIT 获焦、输入语言切换
  // 两个时机各调一次，覆盖「切语言后打字」与「不切语言直接打字」两条路径。
  ImeDiagLog("REATTACH reason=%s edit=%p fg=%p", reason, edit_,
             GetForegroundWindow());
  ImeDiagImeState("REATTACH_BEFORE", himc_);
  ImmAssociateContext(edit_, nullptr);
  ImmAssociateContext(edit_, himc_);
  ImmSetOpenStatus(himc_, TRUE);
  DWORD conv = 0;
  DWORD sentence = 0;
  if (ImmGetConversionStatus(himc_, &conv, &sentence)) {
    ImmSetConversionStatus(himc_, conv | IME_CMODE_NATIVE, sentence);
  }
  ImeDiagImeState("REATTACH_AFTER", himc_);
}

void NativeEditHost::RecreateEditWindow(const char* reason) {
  // 无论是否真正执行，挂起标记都在投递的这条消息处理时解除，允许下次触发。
  recreate_pending_ = false;
  if (!shown_ || !edit_ || !popup_ || !IsWindow(edit_) || !IsWindow(popup_)) {
    healing_bounce_ = false;
    ImeDiagLog("RECREATE_ABORT reason=%s shown=%d", reason, shown_ ? 1 : 0);
    return;
  }
  // 只在键盘焦点确在旧 EDIT 上时重建，避免在用户已点走的窗口上动刀。
  if (GetFocus() != edit_) {
    healing_bounce_ = false;
    ImeDiagLog("RECREATE_ABORT reason=%s focus=%p edit=%p", reason, GetFocus(),
               edit_);
    return;
  }

  HWND old = edit_;
  ImeDiagLog("RECREATE_BEFORE reason=%s old=%p text_len=%d", reason, old,
             GetWindowTextLengthW(old));

  // 保留文本、选区、旧 EDIT 在 popup 内的位置与尺寸。
  const int text_len = GetWindowTextLengthW(old);
  std::wstring text(static_cast<size_t>(text_len) + 1, L'\0');
  const int got = GetWindowTextW(old, text.data(), text_len + 1);
  text.resize(got > 0 ? got : 0);
  DWORD sel_start = 0;
  DWORD sel_end = 0;
  SendMessageW(old, EM_GETSEL, reinterpret_cast<WPARAM>(&sel_start),
               reinterpret_cast<LPARAM>(&sel_end));
  RECT old_rc{};
  GetWindowRect(old, &old_rc);
  POINT tl{old_rc.left, old_rc.top};
  ScreenToClient(popup_, &tl);
  const int ew = old_rc.right - old_rc.left;
  const int eh = old_rc.bottom - old_rc.top;

  // 焦点先暂存 popup（healing_bounce_ 阻止其 WM_SETFOCUS 抢焦不变量）。
  healing_bounce_ = true;
  SetFocus(popup_);

  // TSF 文档绑窗口生命周期：仅销毁重建控件窗口。RichEdit 走原生 TSF，
  // 不再触碰 HIMC（无专属上下文）。
  edit_ = nullptr;
  DestroyWindow(old);

  // 原样新建 RichEdit（与 EnsureCreated 一致），保留文本/选区/位置。
  HWND nw = CreateEditControl(popup_, tl.x, tl.y, ew, eh);
  if (!nw) {
    healing_bounce_ = false;
    ImeDiagLog("RECREATE_FAIL CreateWindowEx err=%lu", GetLastError());
    return;
  }
  edit_ = nw;
  // 新窗口从 0 开始计获焦次数，首次 SetFocus(nw) 不触发 reattach。
  edit_focus_seq_ = 0;
  original_edit_proc_ = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(
      nw, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(&EditWndProc)));
  ApplyEditStyle();
  if (!text.empty()) {
    SetWindowTextW(nw, text.c_str());
  }
  SendMessageW(nw, EM_SETSEL,
               std::min<DWORD>(sel_start, static_cast<DWORD>(text.size())),
               std::min<DWORD>(sel_end, static_cast<DWORD>(text.size())));
  // WS_CHILD 控件创建后默认隐藏，不主动显示会只剩一个不可见的焦点接收者：
  // 候选窗照常弹出、选词成功，但框内看不到任何文字。
  ShowWindow(nw, SW_SHOWNOACTIVATE);

  ImeDiagLog("RECREATE_AFTER new=%p himc=%p fg=%p act=%p", nw, himc_,
             GetForegroundWindow(), GetActiveWindow());
  healing_bounce_ = false;
  SetFocus(nw);
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
  }
  // 字体、底色、文字色、内边距、字数上限统一下发（RichEdit 不吃 WM_CTLCOLOR）。
  ApplyEditStyle();
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
  // 仅当前台就是 owner/popup 本窗口链时才把键盘焦点交给 EDIT。app 在后台
  // （其他应用持前台，或前台是同进程别的顶层窗）时 Dart 仍可能因布局变化/
  // 重建重发 show：此时 SetFocus 会让 EDIT 在前台归属别人时获焦，TSF 照
  // WM_IME_SETCONTEXT(active=1) 建半初始化文档——此后搜狗字母直通、候选窗不
  // 弹，重挂 HIMC 也不可恢复（毒在 TSF 文档状态）。后台只显示不抢焦；用户
  // 真点击时 WM_MOUSEACTIVATE 显式主导焦点转移。
  HWND fg = GetForegroundWindow();
  const DWORD fg_tid =
      fg ? GetWindowThreadProcessId(fg, nullptr) : 0;
  const bool foreground_ours = (fg == parent_ || fg == popup_);
  if (foreground_ours) {
    SetFocus(edit_);
  }
  ImeDiagLog("SHOW host=%p edit=%p focus=%p fg=%p act=%p fg_tid=%lu grab=%d",
             this, edit_, GetFocus(), fg, GetActiveWindow(), fg_tid,
             foreground_ours ? 1 : 0);
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
  healing_bounce_ = false;
  recreate_pending_ = false;
  ImeDiagLog("HIDE host=%p notify=%d", this, notify_dart ? 1 : 0);
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
      // 鼠标点到 EDIT 之外的留白（圆角边/垂直间隙）时，窗口默认处理会把焦点
      // 设给 popup；焦点在容器上停留期间切换 IME、再点回 EDIT，TSF 文档会概率
      // 性半初始化毒化（日志同形序列有时组字成功、有时字母直通不可恢复）。
      // 容器拿到焦点立即还给 EDIT，使「焦点离开 EDIT 到同进程窗口」这一毒化
      // 前置状态无法存在。
      // 例外：healing_bounce_ 期间焦点是重建 EDIT 流程中故意暂存在 popup 的，
      // 抢回会让旧 EDIT 复活、重建无法进行。
      if (self && self->shown_ && self->edit_ && !self->healing_bounce_) {
        ImeDiagLog("POPUP_GOTFOCUS redirect->edit focus=%p", GetFocus());
        SetFocus(self->edit_);
      } else if (self && self->healing_bounce_) {
        ImeDiagLog("HEAL_HOLD popup keeps focus");
      }
      break;

    case kMsgHealRecreate:
      if (self) {
        self->RecreateEditWindow("directkey");
      }
      return 0;

    case WM_MOUSEACTIVATE:
      // 三种点击来源都必须由我们显式主导焦点转移：
      //  - 其他应用持前台：AttachThreadInput 后 SetForegroundWindow(owner) 再
      //    SetFocus(EDIT)，否则前台锁使焦点切换不落地，EDIT 有键盘焦点而前台
      //    仍是他人，TSF 不建活文档。
      //  - owner 主窗持前台（用户刚点过输入框外的 Flutter 区域，焦点在引擎
      //    视图）：必须显式 SetFocus(EDIT)。若此处只返回 MA_NOACTIVATE 而不转
      //    焦，EDIT 靠随后 WM_LBUTTONDOWN 的默认处理被动获焦、popup 被动激活，
      //    TSF 会建出半初始化文档——实测此后搜狗字母直通、候选窗不弹且重挂
      //    HIMC 不可恢复（本应用内点回输入框失效的唯一路径，日志 3:0 对照）。
      //  - popup 自己持前台：同样补一次 SetFocus，幂等。
      if (self) {
        HWND fg = GetForegroundWindow();
        wchar_t fg_class[64] = {};
        if (fg) {
          GetClassNameW(fg, fg_class, _countof(fg_class));
        }
        ImeDiagLog("MOUSEACT shown=%d fg=%p act=%p fgcls=%ls", self->shown_ ? 1 : 0,
                   fg, GetActiveWindow(), fg_class);
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

    case WM_SETFOCUS: {
      // 先让 EDIT 默认过程处理（它在此期间同步发出 WM_IME_SETCONTEXT），
      // 再强制重建 IME 上下文，兜住跨进程往返后 TSF 文档焦点半初始化。
      const LRESULT focus_result = CallWindowProcW(
          self ? self->original_edit_proc_ : DefWindowProcW, hwnd, message,
          wparam, lparam);
      if (self) {
        self->has_focus_ = true;
        InvalidateRect(hwnd, nullptr, TRUE);
        const bool first_focus = (self->edit_focus_seq_++ == 0);
        ImeDiagLog("EDIT_SETFOCUS edit=%p seq=%d", hwnd,
                   self->edit_focus_seq_ - 1);
        ImeDiagLogWnd("setfocus_from", reinterpret_cast<HWND>(lparam));
        // 首次获焦的 HIMC 是 EnsureCreated/RecreateEditWindow 刚关联的全新
        // 上下文，此时再解离/重关联会打断 TSF 对可见新窗口的文档初始化
        // （实测加了可见 ShowWindow 后，重建首焦的 reattach 会让搜狗直通）。
        if (!first_focus) {
          self->ReattachImeContext("setfocus");
        }
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
      // 切语言只重挂 HIMC 做轻量兜底，不再预防性重建 EDIT：健康路径上反复
      // 销毁 TSF 文档本身会制造毒化竞态。真正直通由 WM_KEYDOWN 指纹惰性
      // 自愈。wParam 是字符集，lParam 是新 HKL（0x08040804=搜狗）。
      ImeDiagLog("LANGCHANGE charset=%lu hkl=%08lx",
                 static_cast<unsigned long>(wparam),
                 static_cast<unsigned long>(lparam));
      if (self) {
        self->ReattachImeContext("langchange");
      }
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
      if (self) {
        // 无专属 HIMC：每次按键临时取窗口当前上下文查组字态，用完即释放。
        HIMC ctx = ImmGetContext(hwnd);
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
        // 失效指纹（原生 TSF 实验期仅诊断，不吞键不重建）：中文布局 + IME
        // 打开态 + comp 空，真实字母键却直达；正常链路 IME 吞键后控件只收到
        // VK_PROCESSKEY(0xE5)。用于验证去掉 legacy HIMC 后毒化是否还存在。
        const DWORD kbd_lang =
            static_cast<DWORD>(reinterpret_cast<ULONG_PTR>(
                GetKeyboardLayout(0))) &
            0xFFFF;
        if (ctx && wparam >= 'A' && wparam <= 'Z' && kbd_lang == 0x0804 &&
            ImmGetOpenStatus(ctx)) {
          const LONG comp_len =
              ImmGetCompositionStringW(ctx, GCS_COMPSTR, nullptr, 0);
          if (comp_len == 0) {
            ImeDiagLog(
                "DIRECT_KEY vk=%02lx comp_len=%ld focus=%p fg=%p act=%p",
                static_cast<unsigned long>(wparam), comp_len, GetFocus(),
                GetForegroundWindow(), GetActiveWindow());
          }
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
      if (self) {
        // WA_INACTIVE=0、WA_ACTIVE=1、WA_CLICKACTIVE=2；跨进程往返时序靠它。
        // lParam 是激活对端窗口：失活时为即将获得激活的窗口（可能为 NULL）。
        ImeDiagLog("OWNER_ACT state=%u shown=%d other=%p fg=%p act=%p",
                   LOWORD(wparam), self->shown_ ? 1 : 0,
                   reinterpret_cast<void*>(lparam), GetForegroundWindow(),
                   GetActiveWindow());
      }
      if (self && LOWORD(wparam) == WA_INACTIVE && self->shown_ &&
          self->engine_window_) {
        // 仅当激活对端属于其他线程（真正切到别的应用）才撤回焦点。本 app
        // 窗口间点击会产生同毫秒 WA_ACTIVE→WA_INACTIVE 瞬态，对端仍是本
        // 线程窗口；此时撤焦点会与 EDIT 点击获焦打架（KILLFOCUS/SETFOCUS
        // 风暴），EDIT 最终拿焦点但 owner 激活态已错乱，TSF 不建活文档。
        DWORD other_tid = 0;
        if (lparam) {
          other_tid = GetWindowThreadProcessId(
              reinterpret_cast<HWND>(lparam), nullptr);
        }
        if (other_tid != GetCurrentThreadId()) {
          SetFocus(self->engine_window_);
        }
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
