import 'package:flutter/material.dart';

import '../theme.dart';

/// 统一的网络图片组件。
///
/// 用 Flutter 内置的 [Image.network]（底层走 [ImageCache]，内存级缓存 +
/// 同一 URL 去重），不引入第三方图片库。缩略图由服务端七牛参数控制尺寸，
/// 因此不需要额外的磁盘缓存层。
///
/// 占位底色与错误图标色缺省取自 [AppTheme] 的当前模式取值
/// （暗黑模式下自动切换为深色占位），传值可覆盖。
class NetImage extends StatelessWidget {
  const NetImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.backgroundColor,
    this.errorIcon = Icons.broken_image_outlined,
    this.iconColor,
    this.fallback,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// 占位底色。null = 用主题当前的图片占位色（随明暗模式切换）。
  final Color? backgroundColor;
  final IconData errorIcon;

  /// 错误图标颜色。null = 用主题当前的弱化文字色。
  final Color? iconColor;

  /// 自定义降级内容（例如头像的首字占位）。优先于 [errorIcon]。
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return fallback ?? _errorBox();
    }
    return Image.network(
      url,
      width: width,
      height: height,
      fit: fit,
      gaplessPlayback: true,
      // 加载中显示与占位同色的块，避免列表跳动。
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return SizedBox(width: width, height: height, child: _placeholderBox());
      },
      errorBuilder: (context, error, stack) => fallback ?? _errorBox(),
    );
  }

  Color get _bg => backgroundColor ?? AppTheme.imagePlaceholder;

  Color get _iconTint => iconColor ?? AppTheme.inkTertiary;

  Widget _placeholderBox() =>
      Container(width: width, height: height, color: _bg);

  Widget _errorBox() {
    final base = _shortestSide();
    return Container(
      width: width,
      height: height,
      color: _bg,
      alignment: Alignment.center,
      child: Icon(errorIcon, size: base * 0.45, color: _iconTint),
    );
  }

  double _shortestSide() {
    final w = width ?? double.infinity;
    final h = height ?? double.infinity;
    final s = w < h ? w : h;
    if (s.isFinite) return s;
    return 40;
  }
}
