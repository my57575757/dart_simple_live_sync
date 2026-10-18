import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:simple_live_app/services/windows_native_edit.dart';

/// [NativeEditField] 的控制器：外部（发送/搜索按钮）用它在不依赖回车的情况下
/// 取出当前输入。内部可包裹一个已存在的 [TextEditingController]（如搜索页），
/// 非 Windows 路径直接读写该 controller。
class NativeEditFieldController {
  NativeEditFieldController({TextEditingController? controller, String text = ''})
      : textController =
            controller ?? TextEditingController(text: text);

  final TextEditingController textController;

  NativeEditFieldState? _state;

  String get text => textController.text;
  set text(String value) => textController.text = value;

  /// 把原生 EDIT 中尚未提交的文本同步回 controller 并返回；非 Windows 直接返回文本。
  Future<String> commit() async {
    if (Platform.isWindows) {
      final state = _state;
      return state == null
          ? textController.text
          : await state.commitFromNative();
    }
    return textController.text;
  }

  void clear() {
    textController.clear();
    _state?.syncClearToNative();
  }

  void dispose() {
    textController.dispose();
  }
}

/// 单行文本输入框。
///
/// Windows：渲染一个与目标外观一致的占位件，点击后在其屏幕位置弹出一个
/// WS_POPUP 原生 EDIT（专属 HIMC，绕开 Flutter 引擎 IME 死桥，见
/// flutter/flutter #190042）。其他平台：回落到普通 [TextField]。
class NativeEditField extends StatefulWidget {
  const NativeEditField({
    required this.controller,
    Key? key,
    this.hintText,
    this.fontSize,
    this.textColor,
    this.hintColor,
    this.background,
    this.radius = 20,
    this.horizontalPadding = 12,
    this.maxLength = 200,
    this.borderColor,
    this.autofocus = false,
    this.onSubmitted,
    this.onClosed,
  }) : super(key: key);

  final NativeEditFieldController controller;
  final String? hintText;

  /// 逻辑字号；null 时取 titleMedium（16），与无 style 的 TextField 一致。
  final double? fontSize;
  final Color? textColor;
  final Color? hintColor;
  final Color? background;
  final double radius;
  final double horizontalPadding;
  final int maxLength;

  /// 占位件描边色；null 用主题默认 OutlineInputBorder 描边。
  final Color? borderColor;
  final bool autofocus;

  /// 回车（非 IME 组字状态）提交，参数为当前文本。
  final ValueChanged<String>? onSubmitted;

  /// Esc 关闭输入框。
  final VoidCallback? onClosed;

  @override
  State<NativeEditField> createState() => NativeEditFieldState();
}

class NativeEditFieldState extends State<NativeEditField>
    with WidgetsBindingObserver {
  final GlobalKey _fieldKey = GlobalKey();
  bool _active = false;

  /// 当前挂载所在的模态路由；只订阅一次 popped
  ModalRoute<dynamic>? _route;

  late final void Function(String) _submitCallback = _handleSubmit;
  late final void Function() _closedCallback = _handleClosed;

  WindowsNativeEdit get _svc => WindowsNativeEdit.instance;

  @override
  void initState() {
    super.initState();
    widget.controller._state = this;
    widget.controller.textController.addListener(_onBackingChanged);
    if (Platform.isWindows) {
      WidgetsBinding.instance.addObserver(this);
      if (widget.autofocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _open());
      }
    }
  }

  @override
  void dispose() {
    widget.controller.textController.removeListener(_onBackingChanged);
    if (widget.controller._state == this) {
      widget.controller._state = null;
    }
    if (Platform.isWindows) {
      WidgetsBinding.instance.removeObserver(this);
      if (_svc.onSubmit == _submitCallback) {
        _svc.onSubmit = null;
      }
      if (_svc.onClosed == _closedCallback) {
        _svc.onClosed = null;
      }
      // 只隐藏本实例仍持有的 popup。路由弹出时 completed 已抢先 hide（比
      // dispose 早约 300ms）；若无条件 hide，快速重开时旧实例 dispose 会把
      // 下一个实例刚 show 的 popup 一并关掉。
      if (_active) {
        _active = false;
        unawaited(_svc.hide());
      }
    }
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!Platform.isWindows) {
      return;
    }
    final route = ModalRoute.of(context);
    if (route == null || route == _route) {
      return;
    }
    _route = route;
    // Get.dialog 反向转场默认约 300ms，dispose（原生 hide）在转场结束后才
    // 执行；这期间 EDIT 仍持有系统键盘焦点，下一次回车会被旧 popup 吞掉并
    // 打在正在退出的路由上（框闪退后消失、再按无反应、第三次才出现）。
    // 路由一弹出（didPop 同步完成 popped，早于反向转场与 dispose 约 300ms）
    // 就立即隐藏 popup、把焦点还给引擎窗口。注意不能用 Route.completed：
    // 它在反向转场结束、overlay 移除后才完成，和 dispose 一样晚。
    route.popped.then((_) {
      if (_active) {
        _active = false;
        unawaited(_svc.hide());
      }
    });
  }

  @override
  void didChangeMetrics() => _scheduleRelayout();

  @override
  void didChangeTextScaleFactor() => _scheduleRelayout();

  void _scheduleRelayout() {
    if (!_active) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_active && mounted) {
        _open();
      }
    });
  }

  // 外部改了 backing controller（如清空）时同步到原生 EDIT。
  void _onBackingChanged() {
    if (Platform.isWindows && _active) {
      _svc.setText(widget.controller.textController.text);
    }
  }

  Future<void> _handleSubmit(String raw) async {
    widget.controller.textController.text = raw;
    widget.onSubmitted?.call(raw);
  }

  Future<void> _handleClosed() async {
    widget.controller.textController.text = await _svc.commit();
    if (mounted) {
      setState(() => _active = false);
    }
    widget.onClosed?.call();
  }

  /// 供控制器调用：同步原生文本到 backing controller 并返回。
  Future<String> commitFromNative() async {
    final text = await _svc.commit();
    widget.controller.textController.text = text;
    return text;
  }

  /// 供控制器调用：清空同步到原生（显式，避免与 listener 重复抢时序）。
  void syncClearToNative() {
    if (Platform.isWindows && _active) {
      _svc.setText('');
    }
  }

  Future<void> _open() async {
    final box = _fieldKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) {
      return;
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final origin = box.localToGlobal(Offset.zero);
    // 内缩 1 物理像素，避免 EDIT 底色盖住 Flutter 绘制的圆角描边。
    final rect = nativeEditPhysicalRect(
      globalLogicalOrigin: origin,
      logicalSize: box.size,
      devicePixelRatio: dpr,
    ).deflate(1.0);

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fontLogical =
        widget.fontSize ?? theme.textTheme.titleMedium?.fontSize ?? 16.0;
    _svc.onSubmit = _submitCallback;
    _svc.onClosed = _closedCallback;
    await _svc.show(
      rect: rect,
      fontSizePx:
          MediaQuery.textScalerOf(context).scale(fontLogical) * dpr,
      bgColor:
          (widget.background ?? theme.cardColor).toARGB32(),
      textColor: (widget.textColor ?? scheme.onSurface).toARGB32(),
      hintColor: (widget.hintColor ??
              scheme.onSurface.withValues(alpha: 0.6))
          .toARGB32(),
      radiusPx: (widget.radius * dpr).round(),
      padXPx: (widget.horizontalPadding * dpr).round(),
      hintText: widget.hintText ?? '',
      text: widget.controller.textController.text,
    );
    if (mounted) {
      setState(() => _active = true);
    }
  }

  InputDecoration _decoration() {
    // borderColor==null：用默认 OutlineInputBorder 描边（弹幕条/搜索框外观）；
    // 显式传色：用该色描边（全屏弹幕的半透明白边）。
    final border = widget.borderColor == null
        ? OutlineInputBorder(
            borderRadius: BorderRadius.circular(widget.radius))
        : OutlineInputBorder(
            borderRadius: BorderRadius.circular(widget.radius),
            borderSide: BorderSide(color: widget.borderColor!),
          );
    return InputDecoration(
      hintText: widget.hintText,
      hintStyle: widget.hintColor == null
          ? null
          : TextStyle(color: widget.hintColor),
      counterText: '',
      isDense: true,
      filled: true,
      fillColor: widget.background ?? Theme.of(context).cardColor,
      contentPadding: EdgeInsets.symmetric(
        horizontal: widget.horizontalPadding,
        vertical: 12,
      ),
      border: border,
      enabledBorder: border,
      focusedBorder: border,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) {
      return TextField(
        controller: widget.controller.textController,
        autofocus: widget.autofocus,
        maxLength: widget.maxLength,
        textInputAction: TextInputAction.send,
        style: TextStyle(
          fontSize: widget.fontSize,
          color: widget.textColor,
        ),
        onSubmitted: widget.onSubmitted,
        decoration: _decoration(),
      );
    }

    final style = TextStyle(
      fontSize: widget.fontSize ??
          Theme.of(context).textTheme.titleMedium?.fontSize,
      color: widget.textColor ?? Theme.of(context).colorScheme.onSurface,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _open,
      child: InputDecorator(
        key: _fieldKey,
        isEmpty: true,
        decoration: _decoration(),
        child: Text('', style: style),
      ),
    );
  }
}
