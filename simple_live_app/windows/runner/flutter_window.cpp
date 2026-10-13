#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "native_edit_host.h"

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

  native_edit_host_ = std::make_unique<NativeEditHost>(
      GetHandle(), child_content(),
      flutter_controller_->engine()->messenger());

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
  // host 的通道持有 engine messenger，必须先于 controller 释放。
  native_edit_host_.reset();

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
    case WM_ACTIVATE:
      // EDIT 可见时拦截基类 WM_ACTIVATE 里把焦点强制还给引擎窗口的行为；
      // 引擎已在上面的 HandleTopLevelWindowProc 先收到过本条消息。
      if (native_edit_host_ && native_edit_host_->visible() &&
          LOWORD(wparam) != WA_INACTIVE) {
        native_edit_host_->Refocus();
        return 0;
      }
      break;

    case WM_CTLCOLOREDIT:
      if (native_edit_host_) {
        HBRUSH brush = native_edit_host_->HandleCtlColor(
            reinterpret_cast<HDC>(wparam), reinterpret_cast<HWND>(lparam));
        if (brush) {
          return reinterpret_cast<LRESULT>(brush);
        }
      }
      break;

    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
