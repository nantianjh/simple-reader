import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../actions.dart';
import '../../util/links.dart';
import '../theme.dart';

/// 把正文里的 http(s) 链接渲染成可点击文本。
///
/// 需求约定：客户端不还原服务端的「链接卡片」样式，
/// 只要链接可见、可点、默认用应用内 WebView 打开（可在设置里
/// 切回系统浏览器）即可。
///
/// 链接之外的部分保持 [style] 原样，因此可以整体替换 [Text] 使用。
class LinkifiedText extends StatefulWidget {
  const LinkifiedText({
    super.key,
    required this.text,
    this.style,
    this.maxLines,
    this.selectable = false,
    this.linkColor,
  });

  final String text;
  final TextStyle? style;

  /// 为 null 表示不限制行数。
  final int? maxLines;

  /// 是否使用 [SelectableText]（正文详情页保留长按复制能力）。
  final bool selectable;

  /// 链接颜色。缺省取当前主题的主色（AppTheme.accent）。
  final Color? linkColor;

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  Future<void> _open(String url) async {
    // 统一入口：应用内 WebView 优先（设置可关），失败回退系统浏览器。
    await openLink(context, url);
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    final base = widget.style ??
        TextStyle(
          fontSize: 14.5,
          color: AppTheme.inkPrimary,
          height: 1.6,
        );
    final linkColor = widget.linkColor ?? AppTheme.accent;

    final links = findTextLinks(text);

    // 没有链接时走最朴素的路径，避免无谓地创建手势识别器。
    if (links.isEmpty) {
      if (widget.selectable) {
        return SelectableText(text, style: base, maxLines: widget.maxLines);
      }
      return Text(
        text,
        style: base,
        maxLines: widget.maxLines,
        overflow: widget.maxLines == null
            ? TextOverflow.clip
            : TextOverflow.ellipsis,
      );
    }

    _disposeRecognizers();
    final linkStyle = base.copyWith(
      color: linkColor,
      decoration: TextDecoration.underline,
      decorationColor: linkColor.withValues(alpha: 0.45),
    );

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final link in links) {
      if (link.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, link.start)));
      }
      final recognizer = TapGestureRecognizer()
        ..onTap = () => _open(link.url);
      _recognizers.add(recognizer);
      spans.add(TextSpan(
        text: text.substring(link.start, link.end),
        style: linkStyle,
        recognizer: recognizer,
      ));
      cursor = link.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    final span = TextSpan(style: base, children: spans);

    if (widget.selectable) {
      return SelectableText.rich(span, maxLines: widget.maxLines);
    }
    return Text.rich(
      span,
      maxLines: widget.maxLines,
      overflow:
          widget.maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
    );
  }
}
