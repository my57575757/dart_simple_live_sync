import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/log.dart';

// 仅 Windows：触发原生侧（窗口线程）重建 IME 输入上下文。
//
// Flutter Windows 引擎存在缺陷（flutter/flutter #190042）：窗口焦点切换后，
// 绑定在引擎子窗口上的 IMM32↔TSF 会话会陈旧僵死，Windows 不再发送
// WM_IME_COMPOSITION，表现为英文数字正常、中文无反应。
//
// IMM 上下文只能在窗口所属线程操作：外部进程 / Dart 线程调用
// ImmAssociateContextEx 均失败，且 IACE_DEFAULT 恢复线程默认上下文是
// no-op。真正的修复在 windows/runner 原生侧：ImmCreateContext 建立全新
// 上下文并关联。本服务只负责在检测到回焦 / App 内导航时，向顶层窗口
// PostMessage（WM_APP+0x42），由窗口线程执行重建。
//
// 只用 dart:ffi 且在 start() 内打开系统库：本文件在非 Windows 平台也会被
// 引用，顶层 DynamicLibrary.open 会让 Android/iOS 启动即崩。

const _gaRootOwner = 3;
const _rebuildImeMessage = 0x8042; // WM_APP + 0x42
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

/// 键盘布局（输入法）变化检测：首次仅建立基线
class KeyboardLayoutTransitionMachine {
  int? _hkl;

  bool poll(int hkl) {
    final previous = _hkl;
    _hkl = hkl;
    return previous != null && previous != hkl;
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

typedef _GetKeyboardLayoutNative = IntPtr Function(Uint32 thread);
typedef _GetKeyboardLayoutDart = int Function(int thread);

typedef _PostMessageNative = Int32 Function(
    IntPtr hwnd, Uint32 msg, IntPtr wparam, IntPtr lparam);
typedef _PostMessageDart = int Function(
    int hwnd, int msg, int wparam, int lparam);

class WindowsImeWatchdog extends GetxService {
  Timer? _timer;
  final FocusTransitionMachine _machine = FocusTransitionMachine();
  final KeyboardLayoutTransitionMachine _layoutMachine =
      KeyboardLayoutTransitionMachine();
  int? _rootHwnd;
  File? _logFile;
  int _logBytes = 0;
  int _currentPid = 0;

  late final int Function() _getForeground;
  late final int Function(int, Pointer<Uint32>) _getWindowThreadProcessId;
  late final int Function(int, int) _getAncestor;
  late final int Function(int) _getKeyboardLayout;
  late final int Function(int, int, int, int) _postMessage;

  Future<void> start() async {
    if (!Platform.isWindows || _timer != null) return;

    final user32 = DynamicLibrary.open('user32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');

    _getForeground = user32
        .lookupFunction<_GetForegroundNative, _GetForegroundDart>(
            'GetForegroundWindow');
    _getWindowThreadProcessId = user32.lookupFunction<
        _GetWindowThreadProcessIdNative,
        _GetWindowThreadProcessIdDart>('GetWindowThreadProcessId');
    _getAncestor = user32.lookupFunction<_GetAncestorNative, _GetAncestorDart>(
        'GetAncestor');
    _getKeyboardLayout =
        user32.lookupFunction<_GetKeyboardLayoutNative,
            _GetKeyboardLayoutDart>('GetKeyboardLayout');
    _postMessage = user32.lookupFunction<_PostMessageNative,
        _PostMessageDart>('PostMessageW');
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

    // 键盘布局属于前台窗口线程，仅本窗口前台时采样，用于诊断
    if (ours) {
      final threadId = _getWindowThreadProcessId(foreground, nullptr);
      if (_layoutMachine.poll(_getKeyboardLayout(threadId))) {
        _writeLog('keyboard-layout changed');
      }
    }
  }

  /// 供 App 在应用内切换直播间等导航时调用，通知原生侧重建 IME 会话
  void cycleSession() {
    _writeLog('app-navigation: ${_postRebuild() ? "posted" : "failed"}');
  }

  void _handleTransition(FocusEvent event) {
    // deactivate 由原生 WM_ACTIVATE 处理；回焦时补发一次重建作为保险。
    if (event == FocusEvent.activated) {
      final root = _rootHwnd;
      if (root == null) {
        _writeLog('activated: root window not cached, skip');
        return;
      }
      _writeLog('activated: ${_postRebuild() ? "posted" : "failed"}');
    } else {
      _writeLog('deactivated');
    }
  }

  bool _postRebuild() {
    final root = _rootHwnd;
    if (root == null) return false;
    return _postMessage(root, _rebuildImeMessage, 0, 0) != 0;
  }

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
