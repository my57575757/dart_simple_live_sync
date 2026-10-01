import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/log.dart';

// 仅 Windows：在窗口失焦/回焦的生命周期里预防性重建 IME 输入上下文。
//
// Flutter Windows 引擎存在缺陷（flutter/flutter #190042，官方修复 PR #190043
// 未合并）：窗口焦点切换后，绑定在 HWND 上的 IMM32↔TSF 会话可能僵死，
// Windows 不再发送 WM_IME_COMPOSITION，表现为英文数字正常、中文无反应，
// 且僵死后再 ImmCreateContext / IACE_DEFAULT 都救不回来。
//
// 因此这里采用 PR 验证过的预防策略：窗口失焦时摘除 IMC，回焦后恢复默认 IMC，
// 强制系统在新一次激活时建立全新的 IMM32↔TSF 会话。
//
// 只用 dart:ffi 且在 start() 内打开系统库：本文件在非 Windows 平台也会被引用，
// 顶层 DynamicLibrary.open 会让 Android/iOS 启动即崩。

const _gwChild = 5;
const _gwHwndNext = 2;
const _gaRootOwner = 3;
const _gcsCompstr = 0x0008;
const _iaceDefault = 0x0010;
const _maxLogBytes = 256 * 1024;

enum FocusEvent { activated, deactivated }

/// 消费「本进程是否前台」的轮询序列，只在 true↔false 翻转时产出事件。
/// 首次 poll 仅建立基线不产出，避免启动时产生假事件。
class FocusTransitionMachine {
  bool? _focused;

  FocusEvent? poll(bool focused) {
    final previous = _focused;
    _focused = focused;
    if (previous == null || previous == focused) return null;
    return focused ? FocusEvent.activated : FocusEvent.deactivated;
  }
}

typedef _GetForegroundNative = IntPtr Function();
typedef _GetForegroundDart = int Function();

typedef _GetWindowThreadProcessIdNative = Uint32 Function(IntPtr hwnd, Pointer<Uint32> pid);
typedef _GetWindowThreadProcessIdDart = int Function(int hwnd, Pointer<Uint32> pid);

typedef _GetCurrentProcessIdNative = Uint32 Function();
typedef _GetCurrentProcessIdDart = int Function();

typedef _GetAncestorNative = IntPtr Function(IntPtr hwnd, Uint32 flags);
typedef _GetAncestorDart = int Function(int hwnd, int flags);

typedef _GetWindowNative = IntPtr Function(IntPtr hwnd, Uint32 cmd);
typedef _GetWindowDart = int Function(int hwnd, int cmd);

typedef _GetContextNative = IntPtr Function(IntPtr hwnd);
typedef _GetContextDart = int Function(int hwnd);

typedef _ReleaseContextNative = Int32 Function(IntPtr hwnd, IntPtr himc);
typedef _ReleaseContextDart = int Function(int hwnd, int himc);

typedef _GetCompositionStringNative = Int32 Function(
    IntPtr himc, Uint32 index, Pointer<NativeType> buf, Uint32 len);
typedef _GetCompositionStringDart = int Function(
    int himc, int index, Pointer<NativeType> buf, int len);

typedef _AssociateContextExNative = Int32 Function(
    IntPtr hwnd, IntPtr himc, Uint32 flags);
typedef _AssociateContextExDart = int Function(int hwnd, int himc, int flags);

class WindowsImeWatchdog extends GetxService {
  Timer? _timer;
  final FocusTransitionMachine _machine = FocusTransitionMachine();
  int? _rootHwnd;
  File? _logFile;
  int _logBytes = 0;
  int _currentPid = 0;

  late final int Function() _getForeground;
  late final int Function(int, Pointer<Uint32>) _getWindowThreadProcessId;
  late final int Function(int, int) _getAncestor;
  late final int Function(int, int) _getWindow;
  late final int Function(int) _immGetContext;
  late final int Function(int, int) _immReleaseContext;
  late final int Function(int, int, Pointer<NativeType>, int)
      _immGetCompositionString;
  late final int Function(int, int, int) _immAssociateContextEx;

  Future<void> start() async {
    if (!Platform.isWindows || _timer != null) return;

    final user32 = DynamicLibrary.open('user32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final imm32 = DynamicLibrary.open('imm32.dll');

    _getForeground = user32
        .lookupFunction<_GetForegroundNative, _GetForegroundDart>(
            'GetForegroundWindow');
    _getWindowThreadProcessId = user32.lookupFunction<
        _GetWindowThreadProcessIdNative,
        _GetWindowThreadProcessIdDart>('GetWindowThreadProcessId');
    _getAncestor = user32.lookupFunction<_GetAncestorNative, _GetAncestorDart>(
        'GetAncestor');
    _getWindow = user32.lookupFunction<_GetWindowNative, _GetWindowDart>(
        'GetWindow');
    _immGetContext = imm32.lookupFunction<_GetContextNative, _GetContextDart>(
        'ImmGetContext');
    _immReleaseContext = imm32.lookupFunction<_ReleaseContextNative,
        _ReleaseContextDart>('ImmReleaseContext');
    _immGetCompositionString = imm32.lookupFunction<_GetCompositionStringNative,
        _GetCompositionStringDart>('ImmGetCompositionStringW');
    _immAssociateContextEx = imm32.lookupFunction<_AssociateContextExNative,
        _AssociateContextExDart>('ImmAssociateContextEx');
    _currentPid = kernel32
        .lookupFunction<_GetCurrentProcessIdNative, _GetCurrentProcessIdDart>(
            'GetCurrentProcessId')();

    await _openLog();
    _timer = Timer.periodic(const Duration(milliseconds: 400), (_) => _poll());
    _writeLog('watchdog started (pid=$_currentPid)');
  }

  Future<void> _openLog() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}ime_watchdog.log');
      _logFile = file;
      if (await file.exists()) _logBytes = await file.length();
    } catch (e) {
      Log.w('WindowsImeWatchdog open log failed: $e');
    }
  }

  void _poll() {
    final foreground = _getForeground();
    var ours = false;
    if (foreground != 0) {
      final pidPtr = calloc<Uint32>();
      try {
        _getWindowThreadProcessId(foreground, pidPtr);
        ours = pidPtr.value == _currentPid;
      } finally {
        calloc.free(pidPtr);
      }
    }

    if (ours && _rootHwnd == null) {
      final root = _getAncestor(foreground, _gaRootOwner);
      if (root != 0) _rootHwnd = root;
    }

    final event = _machine.poll(ours);
    if (event != null) _handleTransition(event);
  }

  void _handleTransition(FocusEvent event) {
    final root = _rootHwnd;
    if (root == null) {
      _writeLog('${event.name}: root window not cached, skip');
      return;
    }

    final results = <String>[];
    void walk(int hwnd) {
      if (hwnd == 0) return;
      final ok = event == FocusEvent.deactivated
          ? _detachIfIdle(hwnd)
          : _associateDefault(hwnd) != 0;
      // 同线程读回 himc：detach 后应为 0，default 后应非 0
      final himc = _immGetContext(hwnd);
      if (himc != 0) _immReleaseContext(hwnd, himc);
      results.add(
          '0x${hwnd.toRadixString(16)}:${ok ? "ok" : "skip"}:himc=$himc');

      var child = _getWindow(hwnd, _gwChild);
      while (child != 0) {
        walk(child);
        child = _getWindow(child, _gwHwndNext);
      }
    }

    walk(root);
    _writeLog('${event.name}: ${results.join(", ")}');
  }

  // 摘除 IMC；组词进行中（GCS_COMPSTR 非空）或窗口本无 IMC 时跳过。
  bool _detachIfIdle(int hwnd) {
    final himc = _immGetContext(hwnd);
    if (himc == 0) return false;
    try {
      final composing =
          _immGetCompositionString(himc, _gcsCompstr, nullptr, 0);
      if (composing > 0) return false;
      return _immAssociateContextEx(hwnd, 0, 0) != 0;
    } finally {
      _immReleaseContext(hwnd, himc);
    }
  }

  int _associateDefault(int hwnd) =>
      _immAssociateContextEx(hwnd, 0, _iaceDefault);

  void _writeLog(String message) {
    unawaited(_doWriteLog(message));
  }

  Future<void> _doWriteLog(String message) async {
    final file = _logFile;
    if (file == null) return;
    try {
      final line = '${DateTime.now().toIso8601String()} $message\n';
      final bytes = utf8.encode(line).length;
      if (_logBytes + bytes > _maxLogBytes) {
        await file.writeAsString(line, flush: true);
        _logBytes = bytes;
      } else {
        await file.writeAsString(line, mode: FileMode.append, flush: true);
        _logBytes += bytes;
      }
    } catch (e) {
      Log.w('WindowsImeWatchdog write log failed: $e');
    }
  }

  @override
  void onClose() {
    _timer?.cancel();
    _timer = null;
    super.onClose();
  }
}
