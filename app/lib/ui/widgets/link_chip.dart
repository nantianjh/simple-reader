import 'package:flutter/material.dart';

import '../actions.dart';
import '../../util/links.dart';
import '../theme.dart';

/// 可点击的链接条。
///
/// 用于展示服务端转成「卡片」的链接——客户端不还原卡片样式，
/// 只保证地址可见、可点、默认用应用内 WebView 打开（可回退系统浏览器）。
class LinkChip extends StatelessWidget {
  const LinkChip({super.key, required this.url, this.dense = false});

  final String url;

  /// 紧凑模式：用于列表卡片内，减少纵向占用。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _open(context),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 9 : 12,
          vertical: dense ? 7 : 10,
        ),
        decoration: BoxDecoration(
          color: AppTheme.infoBackground,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.accentBorder, width: 0.8),
        ),
        child: Row(
          children: [
            Icon(Icons.link_rounded,
                size: dense ? 15 : 17, color: AppTheme.accent),
            SizedBox(width: dense ? 7 : 9),
            Expanded(
              child: Text(
                dense ? shortenUrl(url, max: 60) : url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: dense ? 12.5 : 13,
                  color: AppTheme.accent,
                  decoration: TextDecoration.underline,
                  decorationColor: AppTheme.accent.withValues(alpha: 0.34),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.open_in_new_rounded,
                size: dense ? 13 : 15, color: AppTheme.inkTertiary),
          ],
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    // 统一入口：应用内 WebView 优先（设置可关），失败回退系统浏览器。
    await openLink(context, url);
  }
}
