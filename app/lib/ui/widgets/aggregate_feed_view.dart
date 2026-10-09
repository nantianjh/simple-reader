import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../data/settings.dart';
import '../../state/aggregate_feed.dart';
import '../theme.dart';
import 'brightness_aware.dart';
import 'read_tracker.dart';
import 'state_views.dart';

/// 「综合阅读」的结果视图：多个关键词合并成一条按发布时间排序的瀑布流。
///
/// 与分页列表（[PagedPostList]）的区别：
/// * 没有页边界、没有跳页 —— 需求要求"不在界面上标注不同的搜索词抓到的内容"，
///   每一条就是一个卡片，来源信息只存在于数据层；
/// * 追加载是"轮"而不是"页"：滑到底自动对每个还有下一页的关键词再抓一页，
///   新抓到的内容按发布时间插进列表（会做视口锚定，画面不跳）。
class AggregateFeedView extends StatefulWidget {
  const AggregateFeedView({
    super.key,
    required this.controller,
    required this.itemBuilder,
    required this.onOpenSettings,
  });

  final AggregateFeedController controller;

  /// 单条卡片构造（由页面提供，与搜索结果的卡片同一套交互）。
  final Widget Function(BuildContext context, Post post, int index) itemBuilder;

  /// 点「选择关键词」：打开综合阅读设置页。
  final VoidCallback onOpenSettings;

  @override
  State<AggregateFeedView> createState() => _AggregateFeedViewState();
}

class _AggregateFeedViewState extends State<AggregateFeedView> {
  final ScrollController _scroll = ScrollController();
  late final ItemVisibilityTracker _tracker = ItemVisibilityTracker(_scroll);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(AggregateFeedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    widget.controller.removeListener(_onControllerChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  List<String> get _ids => [for (final p in widget.controller.posts) p.id];

  // ----------------------------------------------------- 滑到底自动追加载

  void _onScroll() {
    final ctl = widget.controller;
    if (!mounted || ctl.busy || !ctl.hasMore) return;
    // 上一轮有失败：等用户点「重试」，不自动重试（避免在网络不稳时反复打）。
    if (ctl.lastRoundHadErrors) return;
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.maxScrollExtent - pos.pixels < 700) _loadMore();
  }

  /// 追加载一轮（更旧的内容），并保持视口锚点不跳。
  ///
  /// 新抓到的内容会按发布时间插到列表**中间**（不同关键词的更新速度不同），
  /// 视口位置会被整体推走。做法与分页列表的"高度锚定"同一思路：先记下
  /// 当前视口最上面那条，插入后把它放回原来的视口位置。
  Future<void> _loadMore() async {
    final ctl = widget.controller;
    if (ctl.busy || !ctl.hasMore) return;
    final anchor = _tracker.firstVisibleKey(_ids);
    final anchorTop =
        anchor == null ? null : _tracker.viewportTopOfKey(anchor);
    await ctl.loadMore();
    if (!mounted || anchor == null || anchorTop == null) return;
    await settleFrame();
    if (!mounted || !_scroll.hasClients) return;
    final now = _tracker.viewportTopOfKey(anchor);
    if (now == null) return;
    final delta = now - anchorTop;
    if (delta.abs() < 1) return;
    final target =
        (_scroll.offset + delta).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.jumpTo(target);
  }

  Future<void> _reload({bool forceNetwork = false}) {
    return widget.controller.start(
      AppSettings.instance.aggregateKeywords,
      forceNetwork: forceNetwork,
    );
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    return BrightnessAware(builder: (context, _) => _contents());
  }

  Widget _contents() {
    final ctl = widget.controller;
    return Column(
      children: [
        _header(ctl),
        if (ctl.fromCache && ctl.cachedAt != null)
          CacheHintBar(cachedAt: ctl.cachedAt!, trailing: '可下拉刷新'),
        if (ctl.filteredCount > 0)
          _banner(
            icon: Icons.filter_alt_off_outlined,
            color: AppTheme.inkSecondary,
            background: AppTheme.surfaceMuted,
            text: '已按屏蔽关键词隐藏 ${ctl.filteredCount} 条动态（在「我的 → 搜索」中管理）',
          ),
        Expanded(child: _body(ctl)),
      ],
    );
  }

  Widget _header(AggregateFeedController ctl) {
    final n = ctl.keywords.length;
    return Container(
      color: AppTheme.cardBackground,
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
      child: Row(
        children: [
          Icon(Icons.auto_awesome_rounded, size: 14, color: AppTheme.accent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              n == 0
                  ? '综合阅读'
                  : '综合阅读 · $n 个关键词 · 已读入 ${ctl.itemCount} 条',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.inkSecondary,
              ),
            ),
          ),
          _headerButton(
            tooltip: '选择关键词',
            icon: Icons.tune_rounded,
            onPressed: widget.onOpenSettings,
          ),
          _headerButton(
            tooltip: '刷新（联网取最新）',
            icon: Icons.refresh_rounded,
            onPressed: ctl.busy ? null : () => _reload(forceNetwork: true),
          ),
        ],
      ),
    );
  }

  Widget _headerButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      color: AppTheme.inkSecondary,
      disabledColor: AppTheme.inkDisabled,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
    );
  }

  Widget _body(AggregateFeedController ctl) {
    if (ctl.error != null && ctl.posts.isEmpty) {
      return ErrorView(message: ctl.error!, onRetry: () => _reload());
    }
    // 首轮抓取与「自动续抓到分界」期间都占用整屏等待态：内容是分批进来的，
    // 抓完整批再进入阅读，避免"边抓边读"时列表被反复插入内容。
    if (ctl.loading || ctl.autoFetching) return _loadingView(ctl);
    if (ctl.keywords.isEmpty) return _noKeywords();
    if (ctl.isEmptyResult) return _emptyResult(ctl);

    // 注意：抓取侧的「上次浏览到这儿」只作为停止触发点，
    // 合并列表里不插分界条（用户口径 2026-10-09）。
    return RefreshIndicator(
      onRefresh: () => _reload(forceNetwork: true),
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: 18),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: ctl.posts.length + 1,
        itemBuilder: (context, i) {
          if (i >= ctl.posts.length) return _footer(ctl);
          final post = ctl.posts[i];
          return KeyedSubtree(
            key: _tracker.keyFor(post.id),
            child: widget.itemBuilder(context, post, i),
          );
        },
      ),
    );
  }

  /// 首轮抓取 / 自动续抓的等待态：多关键词串行进行，给出进度与说明。
  Widget _loadingView(AggregateFeedController ctl) {
    final auto = ctl.autoFetching;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(height: 16),
            Text(
              auto ? '正在抓取到「上次浏览到这儿」为止…' : '正在抓取综合阅读的内容…',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.inkPrimary,
              ),
            ),
            if (ctl.progressTotal > 0) ...[
              const SizedBox(height: 8),
              Text(
                '已抓取 ${ctl.progressDone}/${ctl.progressTotal} 个关键词'
                ' · 已读入 ${ctl.itemCount} 条',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: AppTheme.inkTertiary,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              auto
                  ? '每个关键词各自抓到上次看过的位置就停，抓完从最新一条开始看。'
                  : '每个关键词抓最新一页（10 条），合并后按发布时间排序；'
                      '抓过的内容会缓存，下次打开更快。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                color: AppTheme.inkDisabled,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _noKeywords() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome_rounded,
                size: 42, color: AppTheme.accent.withValues(alpha: 0.55)),
            const SizedBox(height: 14),
            Text(
              '还没有选择关键词',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppTheme.inkSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '从你的搜索历史里挑几个词，把它们的最新内容合并到这里阅读。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                color: AppTheme.inkTertiary,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: widget.onOpenSettings,
              child: const Text('去选择关键词'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyResult(AggregateFeedController ctl) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded,
                size: 40, color: AppTheme.inkDisabled),
            const SizedBox(height: 12),
            Text(
              '这些关键词暂时没有抓到内容',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppTheme.inkSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '可以调整关键词名单，或点「刷新」联网再取一次。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                color: AppTheme.inkTertiary,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: () => _reload(forceNetwork: true),
              child: const Text('刷新'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer(AggregateFeedController ctl) {
    Widget child;
    if (ctl.loadingMore) {
      final progress = ctl.progressTotal > 0
          ? '（${ctl.progressDone}/$ctl.progressTotal）'
          : '';
      child = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 15,
            height: 15,
            child: CircularProgressIndicator(strokeWidth: 1.8),
          ),
          const SizedBox(width: 8),
          Text(
            '正在抓取更早的内容…$progress',
            style: TextStyle(fontSize: 12.5, color: AppTheme.inkTertiary),
          ),
        ],
      );
    } else if (ctl.lastRoundHadErrors) {
      child = Column(
        children: [
          Text(
            '部分关键词这次没有抓到内容',
            style: TextStyle(fontSize: 12.5, color: AppTheme.danger),
          ),
          TextButton(
            onPressed: _loadMore,
            child: const Text('重试'),
          ),
        ],
      );
    } else if (ctl.hasMore) {
      child = Text(
        '继续往下滑，自动加载更早的内容',
        style: TextStyle(fontSize: 12, color: AppTheme.inkTertiary),
      );
    } else {
      child = Text(
        '已经到底了 · 共 ${ctl.itemCount} 条',
        style: TextStyle(fontSize: 12.5, color: AppTheme.inkTertiary),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 24),
      child: Center(child: child),
    );
  }

  Widget _banner({
    required IconData icon,
    required Color color,
    required Color background,
    required String text,
  }) {
    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
      child: Row(
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11.5, color: color, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
