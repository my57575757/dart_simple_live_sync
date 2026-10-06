#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "ime_rebuilder.h"

namespace {

// Posted to run IME context work on the window thread after focus processing.
// Dart posts kRebuildImeMessage directly for in-app navigation.
constexpr UINT kRebuildImeMessage = WM_APP + 0x42;
constexpr UINT kDetachImeMessage = WM_APP + 0x43;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Restore the default IMC and destroy self-created contexts before the
  // engine child window goes away, or the active IME TIP may crash on
  // shutdown (observed in SogouPY.ime).
  if (HWND child = child_content()) {
    ShutdownImeContexts(child);
  }

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case kRebuildImeMessage:
      if (HWND child = child_content()) {
        RebuildImeContext(child);
      }
      return 0;
    case kDetachImeMessage:
      if (HWND child = child_content()) {
        DetachImeContext(child);
      }
      return 0;
    case WM_ACTIVATE:
      // Runs after focus/DefWindowProc processing: detach on deactivation,
      // build a fresh context on activation.
      PostMessage(hwnd,
                  LOWORD(wparam) == WA_INACTIVE ? kDetachImeMessage
                                                : kRebuildImeMessage,
                  0, 0);
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
