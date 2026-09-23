import 'package:flutter/material.dart';

import '../../util/format.dart';
import '../theme.dart';
import 'brightness_aware.dart';

/// 本文件里的四个状态视图（加载 / 空 / 错误 / 页脚）都大量使用静态语义色，
/// 而且经常被 `const` 构造调用 —— 常量实例不会被父级 rebuild 带到，自身也
/// 不读 Theme，所以每个视图都包一层 [BrightnessAware]：系统在「跟随系统」
/// 模式下切换明暗时它们能自行重画，不必等调用方重建。

/// 首次加载中。
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) =>
      BrightnessAware(builder: (context, _) => _contents());

  Widget _contents() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          if (message != null) ...[
            const SizedBox(height: 14),
            Text(
              message!,
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.inkTertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 空结果。
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    this.title = '没有找到内容',
    this.subtitle,
    this.icon = Icons.search_off_rounded,
  });

  final String title;
  final String? subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) =>
      BrightnessAware(builder: (context, _) => _contents());

  Widget _contents() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: AppTheme.inkDisabled),
            const SizedBox(height: 14),
            Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppTheme.inkSecondary,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: AppTheme.inkTertiary,
                  height: 1.6,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误视图，带重试。
class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.message,
    this.onRetry,
    this.icon = Icons.error_outline_rounded,
    this.retryLabel = '重试',
  });

  final String message;
  final VoidCallback? onRetry;
  final IconData icon;
  final String retryLabel;

  @override
  Widget build(BuildContext context) =>
      BrightnessAware(builder: (context, _) => _contents());

  Widget _contents() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: AppTheme.danger.withValues(alpha: 0.55)),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: AppTheme.inkSecondary,
                height: 1.6,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 18),
              OutlinedButton(
                onPressed: onRetry,
                child: Text(retryLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 列表内容来自本地缓存时的提示条。
///
/// 搜索 / 收藏 / 个人主页三个分页列表共用同一份文案：用户需要一眼看出
/// "现在看的是抓过的旧内容、还是刚从网络拿的"（并知道自己可以下拉刷新）。
class CacheHintBar extends StatelessWidget {
  const CacheHintBar({
    super.key,
    required this.cachedAt,
    this.trailing = '下拉可刷新',
  });

  /// 缓存抓取时间。
  final DateTime cachedAt;

  /// 右端提示语，传空串则不显示。
  final String trailing;

  @override
  Widget build(BuildContext context) =>
      BrightnessAware(builder: (context, _) => _contents());

  Widget _contents() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
      color: AppTheme.infoBackground,
      child: Row(
        children: [
          Icon(Icons.offline_bolt_outlined, size: 13, color: AppTheme.accent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '内容来自本地缓存（抓取于 ${timeAgo(cachedAt)}）',
              style: TextStyle(fontSize: 11.5, color: AppTheme.accent),
            ),
          ),
          if (trailing.isNotEmpty)
            Text(
              trailing,
              style: TextStyle(fontSize: 11, color: AppTheme.inkTertiary),
            ),
        ],
      ),
    );
  }
}

/// 列表底部状态条：加载中 / 无更多 / 加载失败。
class FooterStatus extends StatelessWidget {
  const FooterStatus({
    super.key,
    required this.busy,
    required this.hasMore,
    this.error,
    this.onRetry,
  });

  final bool busy;
  final bool hasMore;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) =>
      BrightnessAware(builder: (context, _) => _contents());

  Widget _contents() {
    if (busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
        child: Column(
          children: [
            Text(
              error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppTheme.danger),
            ),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('重新加载')),
          ],
        ),
      );
    }
    if (!hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            '已经到底了',
            style: TextStyle(fontSize: 12.5, color: AppTheme.inkTertiary),
          ),
        ),
      );
    }
    return const SizedBox(height: 12);
  }
}
