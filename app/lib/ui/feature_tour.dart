import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets/brightness_aware.dart';

/// 功能导览弹窗。
///
/// 触发时机：**只由用户主动打开** —— 入口在「我的 → 高级设置 → 功能导览」。
/// 需求调整后，登录成功进入主界面时不再自动弹出（原先由 `RootShell` 用
/// `AppSettings.readingIntroShown` 控制自动弹一次）。
///
/// 内容口径：只讲"这个软件怎么用"（订阅合集、解析收藏动态里的合集、
/// 缓存与续读、凭证有效期），不出现任何端点与技术词。
Future<void> showFeatureTour(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => const _FeatureTourDialog(),
  );
}

class _TourItem {
  const _TourItem(this.icon, this.title, this.body);

  final IconData icon;
  final String title;
  final String body;
}

const List<_TourItem> _tourItems = <_TourItem>[
  _TourItem(
    Icons.search_rounded,
    '检索与翻页',
    '输入关键词检索，10 条一页；滑到页尾自动补下一页。'
        '每一页的页首与页尾都有「跳至指定页」，可在已加载的页之间快速跳转。',
  ),
  _TourItem(
    Icons.collections_bookmark_outlined,
    '收藏的合集',
    '收藏页切到「收藏的合集」，点右上角的同步按钮，'
        '软件会从你收藏的动态里解析出合集，收进本机目录（按钮墙）。'
        '首次进入会有一次说明；此后按钮自动判断：目录还空着就完整解析历史收藏，'
        '已有数据时只同步最新 10 条。',
  ),
  _TourItem(
    Icons.notifications_active_rounded,
    '订阅合集',
    '选中合集后点铃铛（或长按上方合集按钮）即可订阅；'
        '每次打开软件会自动检查订阅的合集有无新动态，有更新就在合集名旁标红点。'
        '再点一次铃铛即可取消订阅。',
  ),
  _TourItem(
    Icons.history_rounded,
    '缓存与续读',
    '抓取过的内容会按保留期存在本机（可在「我的 → 高级设置」调整）。'
        '再搜同一个关键词时可以「续读」到上次停留的位置，'
        '续读全程读本地缓存，不发起网络请求；下拉即可刷新。',
  ),
  _TourItem(
    Icons.key_rounded,
    '登录与有效期',
    '登录凭证约 30 天有效，过期后在「我的」页重新登录即可；'
        '凭证只保存在本机，不会上传给任何第三方。',
  ),
];

class _FeatureTourDialog extends StatelessWidget {
  const _FeatureTourDialog();

  @override
  Widget build(BuildContext context) {
    // 弹窗内容全是静态语义色，包一层亮度依赖以便系统明暗切换时自刷新。
    return BrightnessAware(builder: (context, _) => _contents(context));
  }

  Widget _contents(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBackground,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.manage_search_rounded,
                          size: 20, color: AppTheme.accent),
                      const SizedBox(width: 8),
                      Text(
                        '欢迎使用 Simple阅读',
                        style: TextStyle(
                          fontSize: 16.5,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.inkPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '登录成功。花半分钟了解几个核心功能：',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.inkTertiary,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final item in _tourItems) ...[
                      _row(item),
                      const SizedBox(height: 13),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('开始使用'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(_TourItem item) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: AppTheme.accent.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(item.icon, size: 17, color: AppTheme.accent),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.inkPrimary,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                item.body,
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.inkSecondary,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
