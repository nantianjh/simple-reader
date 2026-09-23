import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api/api_config.dart';
import '../api/models.dart';
import '../platform/native_bridge.dart';
import '../util/app_log.dart';

/// 图片保存：下载原图字节 → 原生通道写入系统相册。
///
/// 工程约定零第三方依赖：下载用 `dart:io` 的 [HttpClient]（UA 与 API
/// 客户端同口径），落相册走自建 system 通道的 `saveImage` —— Android 10+
/// 经 MediaStore 插入 `Pictures/Simple阅读`（无需存储权限，相册立即可见），
/// 更早版本没有免权限的公共目录写法，回落应用外部私有目录。
///
/// 产品口径：任何可拿到图片的媒体项都提供保存。
class ImageSaver {
  ImageSaver._();

  /// 同一张图同一时刻只允许一个保存流程（防长按连点 / 重复入队）。
  static final Set<String> _busy = <String>{};

  /// 单图大小上限（约 30MB）：防御异常大文件拖垮通道与相册写入。
  static const int _maxBytes = 30 * 1024 * 1024;

  /// 保存 [m] 指向的图片。
  ///
  /// heic/heif 等可转码图片保存**转码后的 jpg**（相册兼容性最好，原图
  /// Flutter/相册大多解不开），其余保存原图。返回给用户看的位置描述
  /// （如「相册/Simple阅读/xx.jpg」）；失败抛 [Exception]，message 可
  /// 直接展示。
  static Future<String> save(MediaItem m) async {
    final url = m.isTranscodableImage ? m.transcodeUrl : m.url;
    if (url.isEmpty) throw Exception('该图片没有可用的地址');
    if (_busy.contains(url)) throw Exception('这张图片正在保存中');
    _busy.add(url);
    try {
      final bytes = await _download(url);
      // 扩展名经常缺失或不可信：先按内容魔数嗅探，再退回 URL 扩展名，
      // 都没有时按最通用的 jpeg 兜底（写错扩展名会导致相册不显示）。
      final mime = _sniffMime(bytes) ?? _mimeFromUrl(url) ?? 'image/jpeg';
      final fileName = _fileName(url, mime);
      final location =
          await NativeBridge.instance.saveImageToGallery(bytes, fileName, mime);
      log.i(LogTag.ui, '图片已保存：$url → $location');
      return location;
    } finally {
      _busy.remove(url);
    }
  }

  static Future<Uint8List> _download(String url) async {
    final client = HttpClient();
    try {
      client.userAgent = ApiConfig.browserUserAgent;
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('下载失败（HTTP ${response.statusCode}）');
      }
      final builder = BytesBuilder(copy: false);
      var total = 0;
      await for (final chunk in response) {
        total += chunk.length;
        if (total > _maxBytes) throw Exception('图片过大，已取消保存');
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (bytes.isEmpty) throw Exception('下载内容为空');
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  /// 按文件头魔数判断图片类型（JPEG/PNG/GIF/WEBP/BMP）。
  static String? _sniffMime(Uint8List b) {
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (b.length >= 4 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      return 'image/png';
    }
    if (b.length >= 3 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      return 'image/gif';
    }
    if (b.length >= 12 &&
        b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return 'image/webp';
    }
    if (b.length >= 2 && b[0] == 0x42 && b[1] == 0x4D) return 'image/bmp';
    return null;
  }

  static String? _mimeFromUrl(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return null;
    switch (path.substring(dot + 1).toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
    }
    return null;
  }

  /// 生成保存文件名：优先沿用原地址文件名（剥 query、非法字符替换为 _），
  /// 扩展名缺失或与实际类型不符时按嗅探出的 mime 补正。
  static String _fileName(String url, String mime) {
    final segments = Uri.tryParse(url)?.pathSegments ?? const [];
    var name = segments.isEmpty ? '' : segments.last;
    if (name.isEmpty || !name.contains('.')) {
      name = 'simple_${DateTime.now().millisecondsSinceEpoch}';
    }
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

    final extForMime = switch (mime) {
      'image/png' => 'png',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      'image/bmp' => 'bmp',
      _ => 'jpg',
    };
    const known = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'};

    final dot = name.lastIndexOf('.');
    if (dot < 0) return '$name.$extForMime';
    final ext = name.substring(dot + 1).toLowerCase();
    // jpeg 规范化为 jpg；未知扩展名按实际类型重写，避免相册不识别。
    if (!known.contains(ext)) {
      return '${name.substring(0, dot)}.$extForMime';
    }
    if (ext == 'jpeg') return '${name.substring(0, dot)}.jpg';
    return name;
  }
}

/// 保存一张媒体图片并给出过程与结果提示（九宫格长按、全屏查看器共用）。
///
/// 流程：先弹「正在保存图片…」（下载大图有几秒空窗），结束后用结果
/// 覆盖（成功报位置、失败报原因）。[onDone] 在流程结束后回调（查看器
/// 用它复位保存按钮的转圈状态）。
Future<void> saveMediaImage(BuildContext context, MediaItem m,
    {VoidCallback? onDone}) async {
  final startMessenger = ScaffoldMessenger.maybeOf(context);
  startMessenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(content: Text('正在保存图片…')),
    );
  String message;
  try {
    final location = await ImageSaver.save(m);
    message = '已保存到 $location';
  } catch (e) {
    log.w(LogTag.ui, '保存图片失败：${m.url}｜$e');
    message = '保存失败：${_userMessage(e)}';
  } finally {
    onDone?.call();
  }
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// 把异常转成用户可读的一句话（剥掉 "Exception: " 前缀）。
String _userMessage(Object e) {
  var s = e.toString();
  if (s.startsWith('Exception: ')) s = s.substring('Exception: '.length);
  return s;
}
