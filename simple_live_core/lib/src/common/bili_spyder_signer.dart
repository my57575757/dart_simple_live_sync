import 'dart:convert';
import 'dart:typed_data';

import 'package:wasm_run/wasm_run.dart';

/// B 站直播 x25Kn/E、x25Kn/X 协议的 spyder 签名器。
///
/// 内嵌执行 B 站官方 spyder.wasm（Rust/stdweb 编译产物），Dart 侧复刻其
/// stdweb ABI：16 字节值槽（payload + tag）、JS 引用表、数组序列化，
/// 以及 guardian::check_environment 需要的最小 bilibili 页面环境。
class BiliSpyderSigner {
  BiliSpyderSigner._();

  static const int _tagUndefined = 0;
  static const int _tagNull = 1;
  static const int _tagI32 = 2;
  static const int _tagF64 = 3;
  static const int _tagString = 4;
  static const int _tagFalse = 5;
  static const int _tagTrue = 6;
  static const int _tagArray = 7;
  static const int _tagRef = 9;
  static const int _tagRawValue = 15;

  late final WasmInstance _instance;
  late final WasmMemory _memory;
  late final WasmFunction _malloc;
  late final WasmFunction _spyder;

  // guardian 读取的伪页面环境（window/location/document.body.childNodes）
  late final Map<String, dynamic> _location = {
    'href': 'https://live.bilibili.com/blanc/5050?liteVersion=true',
    'protocol': 'https:',
    'host': 'live.bilibili.com',
    'hostname': 'live.bilibili.com',
    'pathname': '/blanc/5050',
    'origin': 'https://live.bilibili.com',
  };
  late final Map<String, dynamic> _document = () {
    final node = <String, dynamic>{
      'nodeType': 1,
      'childNodes': <dynamic>[],
    };
    return {
      'body': {
        'childNodes': [node],
      },
      'childNodes': [node, node],
    };
  }();
  late final Map<String, dynamic> _window = {'location': _location};

  // stdweb JS 引用表
  final Expando<int> _objectToId = Expando<int>('stdweb-ref');
  final Map<int, Object?> _idToObject = {};
  final Map<int, int> _idToRefCount = {};
  int _nextRefId = 1;

  // ff51 snippet 把 spyder 返回值写入此处
  Object? _tmp;

  ByteData get _bd => ByteData.sublistView(_memory.view);
  Uint8List get _heap => _memory.view;

  /// 用 spyder.wasm 字节构造签名器。
  static Future<BiliSpyderSigner> fromBytes(Uint8List bytes) async {
    // 纯 Dart（dart test/console）解析 .dart_tool 下 native hook 拉取的动态库；
    // Flutter 端由 wasm_run_flutter 的 native assets 提供同名库。幂等。
    await WasmRunLibrary.setUp();
    final module = await compileWasmModule(bytes);
    final signer = BiliSpyderSigner._();
    final builder = module.builder();
    signer._addImports(builder);
    signer._instance = await builder.build();
    signer._memory = signer._instance.getMemory('memory')!;
    signer._malloc = signer._instance.getFunction('__web_malloc')!;
    signer._spyder = signer._instance.getFunction('spyder')!;
    return signer;
  }

  /// 对 X 心跳 reportData（JSON 字符串）签名，[rule] 为 E 响应的 secret_rule。
  String sign(String reportJson, List<int> rule) {
    final argJson = _prepareArg(reportJson);
    final argRule = _prepareArg(rule);
    _spyder([argJson, argRule]);
    final result = _tmp;
    _tmp = null;
    if (result is! String || !_hexSignature.hasMatch(result)) {
      throw StateError('spyder 签名返回异常: $result');
    }
    return result;
  }

  static final RegExp _hexSignature = RegExp(r'^[0-9a-f]+$');

  // ---- 值槽编解码（stdweb 16 字节槽）----

  Object? _toJs(int slot) {
    final bd = _bd;
    final tag = bd.getUint8(slot + 12);
    switch (tag) {
      case _tagUndefined:
      case _tagNull:
        return null;
      case _tagI32:
        return bd.getInt32(slot, Endian.little);
      case _tagF64:
        return bd.getFloat64(slot, Endian.little);
      case _tagString:
        final ptr = bd.getUint32(slot, Endian.little);
        final len = bd.getUint32(slot + 4, Endian.little);
        return utf8.decode(
          Uint8List.sublistView(_heap, ptr, ptr + len),
        );
      case _tagFalse:
        return false;
      case _tagTrue:
        return true;
      case _tagArray:
        final base = bd.getUint32(slot, Endian.little); // arena 恒为 0
        final len = bd.getUint32(slot + 4, Endian.little);
        return List<Object?>.generate(
          len,
          (i) => _toJs(base + 16 * i),
          growable: false,
        );
      case _tagRef:
        return _idToObject[bd.getInt32(slot, Endian.little)];
      // tag15(raw value) 的注册 snippet 不在本模块 import 中，只会出现在注销路径
      case _tagRawValue:
        return null;
      default:
        throw StateError('toJs 遇到未知 tag: $tag');
    }
  }

  void _fromJs(int slot, Object? value) {
    final bd = _bd;
    if (value == null) {
      bd.setUint8(slot + 12, _tagNull);
    } else if (value is String) {
      final encoded = utf8.encode(value);
      final ptr = encoded.isEmpty ? 0 : _mallocBytes(encoded);
      bd.setUint32(slot, ptr, Endian.little);
      bd.setUint32(slot + 4, encoded.length, Endian.little);
      bd.setUint8(slot + 12, _tagString);
    } else if (value is bool) {
      bd.setUint8(slot + 12, value ? _tagTrue : _tagFalse);
    } else if (value is int) {
      bd.setInt32(slot, value, Endian.little);
      bd.setUint8(slot + 12, _tagI32);
    } else if (value is double) {
      bd.setFloat64(slot, value, Endian.little);
      bd.setUint8(slot + 12, _tagF64);
    } else {
      bd.setInt32(slot, _acquireRustRef(value), Endian.little);
      bd.setUint8(slot + 12, _tagRef);
    }
  }

  int _prepareArg(Object? value) {
    final slot = _mallocInt(16);
    _fromJs(slot, value);
    return slot;
  }

  void _serializeArray(int slot, List<Object?> array) {
    final n = array.length;
    final items = _mallocInt(16 * n);
    final bd = _bd;
    bd.setUint32(slot, items, Endian.little);
    bd.setUint32(slot + 4, n, Endian.little);
    bd.setUint8(slot + 12, _tagArray);
    for (var i = 0; i < n; i++) {
      _fromJs(items + 16 * i, array[i]);
    }
  }

  // ---- JS 引用计数 ----

  int _acquireRustRef(Object value) {
    final existing = _objectToId[value];
    // Expando 不随 refcount 归零清除（与 stdweb glue 的 WeakMap 行为一致），
    // id 复用时需重建引用表项。
    if (existing != null) {
      final count = _idToRefCount[existing];
      if (count == null) {
        _idToObject[existing] = value;
        _idToRefCount[existing] = 1;
        return existing;
      }
      _idToRefCount[existing] = count + 1;
      return existing;
    }
    final id = _nextRefId++;
    _objectToId[value] = id;
    _idToObject[id] = value;
    _idToRefCount[id] = 1;
    return id;
  }

  void _decrementRefCount(int id) {
    final remaining = (_idToRefCount[id] ?? 1) - 1;
    if (remaining == 0) {
      _idToRefCount.remove(id);
      _idToObject.remove(id);
    } else {
      _idToRefCount[id] = remaining;
    }
  }

  // ---- wasm 内存 ----

  int _mallocInt(int size) => _malloc([size]).first as int;

  int _mallocBytes(List<int> bytes) {
    final ptr = _mallocInt(bytes.length);
    _heap.setRange(ptr, ptr + bytes.length, bytes);
    return ptr;
  }

  // ---- host imports（21 个 stdweb snippet + __web_on_grow）----

  void _addImports(WasmInstanceBuilder builder) {
    WasmFunction fn1(Int32Snippet f) => WasmFunction(
      f,
      params: const [ValueTy.i32],
      results: const [ValueTy.i32],
    );
    WasmFunction fn2(Int32PairSnippet f) => WasmFunction(
      f,
      params: const [ValueTy.i32, ValueTy.i32],
      results: const [ValueTy.i32],
    );

    builder
      ..addImport(
        'env',
        '__cargo_web_snippet_80d6d56760c65e49b7be8b6b01c1ea861b046bf0',
        fn1((id) {
          _decrementRefCount(id);
          return 0;
        }),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_e9638d6405ab65f78daf4a5af9c9de14ecf1e2ec',
        fn1((slot) {
          // 注销 raw value：本模块没有注册路径，求值槽位后丢弃
          _toJs(slot);
          return 0;
        }),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_ff5103e6cc179d13b4c7a785bdce2708fd559fc0',
        fn1((slot) {
          _tmp = _toJs(slot);
          return 0;
        }),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_10f5aa3985855124ab83b21d4e9f7297eb496508',
        fn1((id) => _idToObject[id] is List ? 1 : 0),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_b33a39de4ca954888e26fe9caa277138e808eeba',
        fn2((outSlot, arraySlot) {
          final array = _toJs(arraySlot) as List;
          _fromJs(outSlot, array.length);
          return 0;
        }),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_8c32019649bb581b1b742eeedfc410e2bedd56a6',
        fn2((id, outSlot) {
          _serializeArray(outSlot, _idToObject[id]! as List<Object?>);
          return 0;
        }),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_0d39c013e2144171d64e2fac849140a7e54c939a',
        fn2((outSlot, windowSlot) {
          _fromJs(
            outSlot,
            (_toJs(windowSlot)! as Map<String, dynamic>)['location'],
          );
          return 0;
        }),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_0f503de1d61309643e0e13a7871406891e3691c9',
        fn1((outSlot) {
          _fromJs(outSlot, _window);
          return 0;
        }),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_2b0b92aee0d0de6a955f8e5540d7923636d951ae',
        fn2((outSlot, slot) => _packField(outSlot, slot, (o) => o['origin'])),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_461d4581925d5b0bf583a3b445ed676af8701ca6',
        fn2((outSlot, slot) => _packField(outSlot, slot, (o) => o['host'])),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_4c895ac2b754e5559c1415b6546d672c58e29da6',
        fn2(
          (outSlot, slot) => _packField(outSlot, slot, (o) => o['protocol']),
        ),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_614a3dd2adb7e9eac4a0ec6e59d37f87e0521c3b',
        fn2((outSlot, slot) {
          _fromJs(
            outSlot,
            (_toJs(slot)! as Map<String, dynamic>)['error'],
          );
          return 0;
        }),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_62ef43cf95b12a9b5cdec1639439c972d6373280',
        fn2((outSlot, slot) {
          _fromJs(
            outSlot,
            (_toJs(slot)! as Map<String, dynamic>)['childNodes'],
          );
          return 0;
        }),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_6fcce0aae651e2d748e085ff1f800f87625ff8c8',
        fn1((outSlot) {
          _fromJs(outSlot, _document);
          return 0;
        }),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_7ba9f102925446c90affc984f921f414615e07dd',
        fn2((outSlot, slot) {
          _fromJs(
            outSlot,
            (_toJs(slot)! as Map<String, dynamic>)['body'],
          );
          return 0;
        }),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_897ff2d0160606ea98961935acb125d1ddbf4688',
        fn1((id) => 0),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_a466a2ab96cd77e1a77dcdb39f4f031701c195fc',
        fn2(
          (outSlot, slot) => _packField(outSlot, slot, (o) => o['pathname']),
        ),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_ab05f53189dacccf2d365ad26daa407d4f7abea9',
        fn2((outSlot, slot) {
          _fromJs(
            outSlot,
            (_toJs(slot)! as Map<String, dynamic>)['value'],
          );
          return 0;
        }),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_b06dde4acf09433b5190a4b001259fe5d4abcbc2',
        fn2((outSlot, slot) {
          _fromJs(
            outSlot,
            (_toJs(slot)! as Map<String, dynamic>)['success'],
          );
          return 0;
        }),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_cdf2859151791ce4cad80688b200564fb08a8613',
        fn2((outSlot, slot) => _packField(outSlot, slot, (o) => o['href'])),
      )
      ..addImport(
        'env',
        '__cargo_web_snippet_e8ef87c41ded1c10f8de3c70dea31a053e19747c',
        fn2(
          (outSlot, slot) => _packField(outSlot, slot, (o) => o['hostname']),
        ),
      )
      ..addImport(
        'env',
        '__web_on_grow',
        WasmFunction.voidReturn(() {}, params: const []),
      );
  }

  int _packField(
    int outSlot,
    int slot,
    Object? Function(Map<String, dynamic> obj) pick,
  ) {
    Object? packed;
    try {
      packed = {
        'value': pick(_toJs(slot)! as Map<String, dynamic>),
        'success': true,
      };
    } catch (e) {
      packed = {'error': e.toString(), 'success': false};
    }
    _fromJs(outSlot, packed);
    return 0;
  }
}

typedef Int32Snippet = int Function(int);
typedef Int32PairSnippet = int Function(int, int);
