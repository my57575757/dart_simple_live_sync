#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "flutter/standard_method_codec.h"
#include "ime_rebuilder.h"

namespace {

// IME context work runs on the window thread. The Dart IME lifecycle client
// posts these when a text input client starts/stops.
constexpr UINT kAttachImeMessage = WM_APP + 0x42;
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

  ime_channel_ = std::make_unique<flutter::MethodChannel<>>(
      flutter_controller_->engine()->messenger(), "simple_live/ime",
      &flutter::StandardMethodCodec::GetInstance());
  ime_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<>& call,
             std::unique_ptr<flutter::MethodResult<>> result) {
        // Hop to the window thread so IME work is serialized with WM_ACTIVATE
        // and never re-enters inside an engine platform-channel callback.
        UINT msg = call.method_name() == "attach" ? kAttachImeMessage
                                                 : kDetachImeMessage;
        PostMessage(GetHandle(), msg, 0, 0);
        result->Success();
      });

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
    case kAttachImeMessage:
      if (HWND child = child_content()) {
        AttachImeContext(child);
      }
      return 0;
    case kDetachImeMessage:
      if (HWND child = child_content()) {
        DetachImeContext(child);
      }
      return 0;
    case WM_ACTIVATE:
      // Detach synchronously on deactivation so a stale context is never
      // carried into the next activation. Activation does nothing: the next
      // text input client start posts its own attach.
      if (LOWORD(wparam) == WA_INACTIVE) {
        if (HWND child = child_content()) {
          DetachImeContext(child);
        }
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
