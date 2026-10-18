#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "desktop_multi_window/desktop_multi_window_plugin.h"
#include "native_edit_host.h"
#include "win32_snap_eligibility.h"

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
  // desktop_multi_window：子窗由原生创建、子引擎独立，须在回调里为其注册插件；
  // void* 即 flutter::FlutterViewController*（见头文件 typedef）
  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController *>(controller);
    auto *registry = flutter_view_controller->engine();
    RegisterPlugins(registry);
    // 子窗原生弹幕 EDIT：自注册自释放，不持有指针。owner 取顶层 HWND
    // （与插件 desktop_multi_window_plugin.cpp 取法一致）。
    HWND child = flutter_view_controller->view()->GetNativeWindow();
    if (child) {
      HWND top = GetAncestor(child, GA_ROOT);
      if (top) {
        // 子窗创建后立即补贴靠资格，并挂 WM_SHOWWINDOW 钩子兜异步 Show 竞态
        HookSnapEligibleOnShow(top);
        new NativeEditHost(top, child, registry->messenger());
      }
    }
  });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 主窗原生弹幕 EDIT：自注册自释放（owner WM_NCDESTROY 时 delete this）。
  new NativeEditHost(GetHandle(), child_content(),
                     flutter_controller_->engine()->messenger());

  // 主窗创建后补贴靠资格，并挂 WM_SHOWWINDOW 钩子兜异步 Show 竞态
  HookSnapEligibleOnShow(GetHandle());

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
  // NativeEditHost 自释放于 owner 的 WM_NCDESTROY，这里不持有指针。
  // 通道析构不触碰 messenger；引擎释放前窗口已先走 NCDESTROY。

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

  // NativeEditHost 的 WM_ACTIVATE/WM_MOVE/WM_SIZE 由其 SetWindowSubclass 自处理。
  if (message == WM_FONTCHANGE) {
    flutter_controller_->engine()->ReloadSystemFonts();
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
