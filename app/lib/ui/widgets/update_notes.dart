import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../data/changelog.dart';
import '../theme.dart';
import 'brightness_aware.dart';

/// 弹出「更新内容」。
///
/// 三种用法：
/// * 启动时自动弹（已知上次版本）—— 传 [fromVersion]，只列出比它新的版本记录；
/// * 启动时自动弹（本机没有记录，但判断为老用户升级）—— [latestOnly] 为 true，
///   只列当前这一版，避免把建表以来的全部历史一次性砸给用户；
/// * 手动查看 —— [showAll] 为 true，列出全部记录（「高级设置 → 更新内容」入口）。
///
/// 内容源是 [Changelog] 的常量表；这里只负责排版与滚动，不参与"该不该弹"的判断
/// （那是外壳的职责，见 `RootShell`）。
Future<void> showUpdateNotesDialog(
  BuildContext context, {
  String? fromVersion,
  bool showAll = false,
  bool latestOnly = false,
}) {
  final current = Changelog.current;
  final notes = showAll
      ? Changelog.releases
      : latestOnly
          ? <ReleaseNote>[if (current != null) current]
          : Changelog.since(fromVersion);
  if (notes.isEmpty) return Future<void>.value();

  final title = showAll ? '更新内容' : '已更新到 v${AppInfo.version}';

  return showDialog<void>(
    context: context,
    builder: (ctx) => BrightnessAware(
      builder: (ctx, _) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
        contentPadding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: const TextStyle(fontSize: 17)),
            const SizedBox(height: 4),
            Text(
              showAll
                  ? '本机记录到的全部版本变化（${notes.length} 个版本）'
                  : '以下是这次更新带来的变化',
              style: TextStyle(fontSize: 12, color: AppTheme.inkTertiary),
            ),
          ],
        ),
        content: ConstrainedBox(
          // 版本多、条目多时靠滚动兜住，不让弹窗撑破屏幕。
          constraints: BoxConstraints(
            maxWidth: 460,
            maxHeight: MediaQuery.of(ctx).size.height * 0.55,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final r in notes) _releaseBlock(r, first: r == notes.first),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    ),
  );
}

/// 一个版本的记录块：版本号 + 日期 + 条目。
Widget _releaseBlock(ReleaseNote r, {required bool first}) {
  return Padding(
    padding: EdgeInsets.only(top: first ? 2 : 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'v${r.version}',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.accent,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              r.date,
              style: TextStyle(fontSize: 11.5, color: AppTheme.inkTertiary),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final c in r.changes)
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 7, right: 7),
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppTheme.inkTertiary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    c,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.55,
                      color: AppTheme.inkPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
