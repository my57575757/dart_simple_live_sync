import 'dart:ffi';

// 仅 Windows：重置窗口的原生 IME 输入上下文。
//
// Flutter Windows 引擎存在已知缺陷（flutter/flutter #190042）：窗口重新获焦后，
// 绑定在 Flutter 子窗口上的 IMM32↔TSF 会话可能失效，表现为英文数字可输入、
// 中文输入法无反应，重焦点输入框也无法恢复。对窗口及全部子窗口调用
// ImmAssociateContextEx(hwnd, NULL, IACE_DEFAULT) 恢复为默认输入上下文即可。
//
// 这里只用 dart:ffi 并在函数内部按需打开系统库：本文件在非 Windows 平台也会
// 被引用，不能在顶层 DynamicLibrary.open（否则 Android/iOS 启动即崩）。
// 窗口树用 GetWindow 同步遍历，避免 NativeCallable 在同步枚举时的限制。

const _iaceDefault = 0x0010;
const _gwChild = 5;
const _gwHwndNext = 2;

typedef _GetForegroundNative = IntPtr Function();
typedef _GetForegroundDart = int Function();

typedef _GetWindowNative = IntPtr Function(IntPtr hwnd, Uint32 cmd);
typedef _GetWindowDart = int Function(int hwnd, int cmd);

typedef _AssociateNative = Int32 Function(IntPtr hwnd, IntPtr himc, Uint32 flags);
typedef _AssociateDart = int Function(int hwnd, int himc, int flags);

int resetWindowsIme() {
  final user32 = DynamicLibrary.open('user32.dll');
  final imm32 = DynamicLibrary.open('imm32.dll');

  final getForeground = user32
      .lookupFunction<_GetForegroundNative, _GetForegroundDart>('GetForegroundWindow');
  final getWindow = user32.lookupFunction<_GetWindowNative, _GetWindowDart>(
    'GetWindow',
  );
  final associate = imm32.lookupFunction<_AssociateNative, _AssociateDart>(
    'ImmAssociateContextEx',
  );

  final foreground = getForeground();
  if (foreground == 0) return 0;

  var reset = 0;
  void resetHwnd(int hwnd) {
    if (hwnd == 0) return;
    if (associate(hwnd, 0, _iaceDefault) != 0) reset++;
    // 深度优先：第一个子窗口，再沿兄弟链
    var child = getWindow(hwnd, _gwChild);
    while (child != 0) {
      resetHwnd(child);
      child = getWindow(child, _gwHwndNext);
    }
  }

  resetHwnd(foreground);
  return reset;
}
