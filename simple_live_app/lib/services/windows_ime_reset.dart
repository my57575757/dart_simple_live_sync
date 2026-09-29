import 'dart:ffi';

// 仅 Windows：重建窗口的原生 IME 输入上下文。
//
// Flutter Windows 引擎存在已知缺陷（flutter/flutter #190042）：窗口重新获焦后，
// 绑定在 Flutter 子窗口上的 IMM32↔TSF 会话可能失效，表现为英文数字可输入、
// 中文输入法无反应，重焦点输入框也无法恢复。
//
// 不能用 ImmAssociateContextEx(hwnd, NULL, IACE_DEFAULT) 处理：故障窗口关联的
// 本就是默认输入上下文，实测该调用在这种情况下是空操作——无论是否先解除关联，
// 返回的都是同一个 HIMC，僵死的会话原样保留。这里改为 ImmCreateContext 新建
// 输入上下文并用 ImmAssociateContext 替换，强制建立全新的 IMM32↔TSF 会话，
// 同时恢复原 IME 打开状态。系统默认 IMC 绝不能销毁，只回收本文件创建的 IMC。
//
// 只用 dart:ffi 并在函数内部按需打开系统库：本文件在非 Windows 平台也会被引用，
// 不能在顶层 DynamicLibrary.open（否则 Android/iOS 启动即崩）。
// 窗口树用 GetWindow 同步遍历，避免 NativeCallable 在同步枚举时的限制。

const _gwChild = 5;
const _gwHwndNext = 2;

typedef _GetForegroundNative = IntPtr Function();
typedef _GetForegroundDart = int Function();

typedef _GetWindowNative = IntPtr Function(IntPtr hwnd, Uint32 cmd);
typedef _GetWindowDart = int Function(int hwnd, int cmd);

typedef _GetContextNative = IntPtr Function(IntPtr hwnd);
typedef _GetContextDart = int Function(int hwnd);

typedef _ReleaseContextNative = Int32 Function(IntPtr hwnd, IntPtr himc);
typedef _ReleaseContextDart = int Function(int hwnd, int himc);

typedef _GetOpenStatusNative = Int32 Function(IntPtr himc);
typedef _GetOpenStatusDart = int Function(int himc);

typedef _SetOpenStatusNative = Int32 Function(IntPtr himc, Int32 open);
typedef _SetOpenStatusDart = int Function(int himc, int open);

typedef _CreateContextNative = IntPtr Function();
typedef _CreateContextDart = int Function();

typedef _AssociateContextNative = IntPtr Function(IntPtr hwnd, IntPtr himc);
typedef _AssociateContextDart = int Function(int hwnd, int himc);

typedef _DestroyContextNative = Int32 Function(IntPtr himc);
typedef _DestroyContextDart = int Function(int himc);

// 记录本文件创建、当前仍关联在窗口上的 IMC，重复重置时才能安全回收。
final Set<int> _ownedContexts = {};

int resetWindowsIme() {
  final user32 = DynamicLibrary.open('user32.dll');
  final imm32 = DynamicLibrary.open('imm32.dll');

  final getForeground = user32
      .lookupFunction<_GetForegroundNative, _GetForegroundDart>('GetForegroundWindow');
  final getWindow = user32.lookupFunction<_GetWindowNative, _GetWindowDart>(
    'GetWindow',
  );
  final getContext = imm32.lookupFunction<_GetContextNative, _GetContextDart>(
    'ImmGetContext',
  );
  final releaseContext = imm32.lookupFunction<_ReleaseContextNative,
      _ReleaseContextDart>('ImmReleaseContext');
  final getOpenStatus = imm32.lookupFunction<_GetOpenStatusNative,
      _GetOpenStatusDart>('ImmGetOpenStatus');
  final setOpenStatus = imm32.lookupFunction<_SetOpenStatusNative,
      _SetOpenStatusDart>('ImmSetOpenStatus');
  final createContext = imm32.lookupFunction<_CreateContextNative,
      _CreateContextDart>('ImmCreateContext');
  final associateContext = imm32.lookupFunction<_AssociateContextNative,
      _AssociateContextDart>('ImmAssociateContext');
  final destroyContext = imm32.lookupFunction<_DestroyContextNative,
      _DestroyContextDart>('ImmDestroyContext');

  final foreground = getForeground();
  if (foreground == 0) return 0;

  var reset = 0;
  void resetHwnd(int hwnd) {
    if (hwnd == 0) return;

    var wasOpen = 0;
    final oldImc = getContext(hwnd);
    if (oldImc != 0) {
      wasOpen = getOpenStatus(oldImc);
      releaseContext(hwnd, oldImc);
    }

    final newImc = createContext();
    if (newImc != 0) {
      final previous = associateContext(hwnd, newImc);
      if (previous != 0 && _ownedContexts.remove(previous)) {
        destroyContext(previous);
      }
      if (wasOpen != 0) setOpenStatus(newImc, 1);
      _ownedContexts.add(newImc);
      reset++;
    }

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
