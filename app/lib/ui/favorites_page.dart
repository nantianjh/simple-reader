import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../state/collections_state.dart';
import '../state/favorites_state.dart';
import '../state/load_phase.dart';
import '../util/app_log.dart';
import '../util/format.dart';
import 'actions.dart';
import 'collection_detail_page.dart';
import 'favorites_collections_view.dart';
import 'post_detail_page.dart';
import 'shell_nav.dart';
import 'theme.dart';
import 'widgets/brightness_aware.dart';
import 'widgets/paged_post_list.dart';
import 'widgets/post_card.dart';
import 'widgets/read_tracker.dart';
import 'widgets/state_views.dart';

/// 收藏页（底部标签页）。
///
/// 需求调整后本页承载**两种收藏**，顶部切换按钮在两者间切换：
/// * **动态**：拉取与翻页走 `/api/v2/favourites`（候选接口依次探测），
///   分页与续读行为与搜索页一致（10 条一页、双向补页、续读记住页号）；
/// * **合集**：原「我的 → 收藏夹（合集）」整页迁入
///   （[FavoritesCollectionsView]），顶部按钮墙选合集、下方看内容，
///   同步口径与移除/恢复交互原样保留。
enum _FavoritesView { posts, collections }

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scroll = ScrollController();
  late final FavoritesController _favorites;
  late final CollectionsController _collections;
  late final ItemVisibilityTracker _tracker;

  /// 合集视图的句柄：AppBar 上的同步动作要调视图里的对话框。
  final GlobalKey<FavoritesCollectionsViewState> _collectionsViewKey =
      GlobalKey();

  _FavoritesView _view = _FavoritesView.posts;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    _tracker = ItemVisibilityTracker(_scroll);
    _favorites = FavoritesController(
      tokenProvider: () => app.token,
    )..onAuthFailure = (msg) {
        if (mounted) app.markUnauthorized(msg);
      };
    // 合集目录控制器：不再自动同步（需求调整），收录只由 AppBar 的
    // 「同步 / 完整同步」手动触发。
    _collections = CollectionsController(
      tokenProvider: () => app.token,
    )..onAuthFailure = (msg) {
        if (mounted) app.markUnauthorized(msg);
      };
    ShellNav.index.addListener(_onShellChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _favorites.ensureLoaded();
    });
  }

  @override
  void dispose() {
    ShellNav.index.removeListener(_onShellChanged);
    _scroll.dispose();
    _favorites.dispose();
    _collections.dispose();
    super.dispose();
  }

  /// 切回收藏页时：动态视图若上次没加载成功就再试。
  /// 合集视图不自动同步：收录只由 AppBar 的同步按钮手动触发。
  void _onShellChanged() {
    if (ShellNav.index.value != ShellNav.favourites) return;
    if (!_favorites.loadedOnce && !_favorites.busy) {
      _favorites.ensureLoaded();
    }
  }

  /// 跳到存档页并滚到存档条目（停留位置）。
  Future<void> _jumpToReadPosition() async {
    final pos = _favorites.savedPosition;
    if (pos == null) return;
    log.i(
      LogTag.read,
      '收藏夹续读 → 第 ${pos.page + 1} 页（条目 ${pos.postId}，'
      '停留于 ${timeAgo(pos.updatedAt)}）',
    );

    if (!_favorites.hasPage(pos.page)) {
      await _favorites.jumpToPage(pos.page);
    }
    if (!mounted) return;
    // 已读线按存档单独恢复：停留位置可能比"读到过哪里"更靠前。
    _favorites.restoreReadLine(pos);

    if (_favorites.indexOfPostId(pos.postId) < 0) {
      log.w(LogTag.read, '续读锚点不在当前页（内容可能已变动），退回页首');
      if (_scroll.hasClients) _scroll.jumpTo(0);
      return;
    }
    await settleFrame();
    if (!mounted) return;
    await scrollToTrackedItem(
      scroll: _scroll,
      tracker: _tracker,
      id: pos.postId,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 包一层亮度依赖：本页配色全是静态语义色，系统在「跟随系统」模式下
    // 切换明暗时必须重建，否则已挂载的列表与顶部按钮墙会停在旧主题。
    return BrightnessAware(builder: (context, _) => _contents(context));
  }

  Widget _contents(BuildContext context) {
    final app = AppScope.of(context);
    final hasPosition = _favorites.savedPosition != null;
    final collectionsView = _view == _FavoritesView.collections;

    return Scaffold(
      backgroundColor: AppTheme.pageBackground,
      appBar: AppBar(
        title: const Text('收藏'),
        actions: [
          // 两个视图的动作按钮互不混杂：动态视图给续读/刷新；
          // 合集视图给同步（单按钮）+ 移除恢复/清空入口。
          if (!collectionsView) ...[
            if (hasPosition)
              TextButton.icon(
                onPressed: _jumpToReadPosition,
                icon: const Icon(Icons.bookmark_outline_rounded, size: 16),
                label: const Text('续读', style: TextStyle(fontSize: 12.5)),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            IconButton(
              tooltip: '重新拉取',
              onPressed:
                  _favorites.busy ? null : () => _favorites.refresh(),
              icon: const Icon(Icons.refresh_rounded, size: 20),
            ),
          ] else
            AnimatedBuilder(
              animation: _collections,
              builder: (context, _) => _collectionActions(),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(46),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
            child: SegmentedButton<_FavoritesView>(
              segments: const [
                ButtonSegment(
                  value: _FavoritesView.posts,
                  label: Text('收藏的动态'),
                  icon: Icon(Icons.star_border_rounded, size: 16),
                ),
                ButtonSegment(
                  value: _FavoritesView.collections,
                  label: Text('收藏的合集'),
                  icon: Icon(Icons.collections_bookmark_outlined, size: 16),
                ),
              ],
              selected: {_view},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _view = s.first),
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(
                  TextStyle(fontSize: 12.5),
                ),
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (app.status == AuthStatus.invalid && app.errorMessage != null)
              AuthBanner(message: app.errorMessage!),
            Expanded(
              child: collectionsView
                  ? FavoritesCollectionsView(
                      key: _collectionsViewKey,
                      collections: _collections,
                      ownerUserId:
                          app.currentUser?.id ?? app.jwt?.userId ?? '',
                    )
                  : AnimatedBuilder(
                      animation: _favorites,
                      builder: (context, _) => _postsBody(),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// 合集视图的 AppBar 动作：同步（单按钮）+ 更多（恢复 / 清空）。
  ///
  /// 同步是**一条命令两种口径**：本机目录还空着时＝完整同步（翻遍全部收藏
  /// 动态），已有数据时＝只同步最新 10 条。判定与执行都在视图内
  /// （[FavoritesCollectionsViewState.syncSmart]），这里只按状态给图标与文案。
  /// 该按钮不再弹说明/确认框 —— 原理与使用前提集中在视图首次进入时的说明页。
  ///
  /// 其余对话框（清空等）也在视图内（要读 controller 的实时状态），经 GlobalKey
  /// 调用；视图尚未挂载（首次切过来前一帧）时静默忽略。
  Widget _collectionActions() {
    final collections = _collections;
    final empty = collections.items.isEmpty;
    void call(void Function(FavoritesCollectionsViewState s) fn) {
      final s = _collectionsViewKey.currentState;
      if (s != null) fn(s);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: empty
              ? '解析收藏动态，建立合集列表（首次为完整解析）'
              : '同步最新收藏动态',
          onPressed:
              collections.busy ? null : () => call((s) => s.syncSmart()),
          icon: Icon(
            empty ? Icons.cloud_sync_outlined : Icons.sync_rounded,
            size: 20,
          ),
        ),
        PopupMenuButton<String>(
          tooltip: '更多',
          onSelected: (v) {
            if (v == 'restore') {
              call((s) => s.restoreRemoved());
            } else if (v == 'clear') {
              call((s) => s.clearAll());
            }
          },
          itemBuilder: (ctx) => [
            PopupMenuItem(
              value: 'restore',
              enabled: collections.removedCount > 0,
              child: Text(
                '恢复已移除的 ${collections.removedCount} 个合集',
                style: const TextStyle(fontSize: 14),
              ),
            ),
            const PopupMenuItem(
              value: 'clear',
              child: Text('清空本机收藏夹', style: TextStyle(fontSize: 14)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _postsBody() {
    if (_favorites.phase == LoadPhase.loadingFirst &&
        _favorites.posts.isEmpty) {
      return const LoadingView(message: '正在拉取收藏夹…');
    }
    if (_favorites.phase == LoadPhase.error && _favorites.posts.isEmpty) {
      return ErrorView(
        message: _favorites.error ?? '加载失败',
        onRetry: _favorites.retry,
      );
    }
    if (_favorites.isEmptyResult) {
      return EmptyView(
        icon: Icons.star_border_rounded,
        title: '收藏夹还是空的',
        subtitle: '在详情页点「收藏」，内容就会出现在这里。\n'
            '当前接口：${_favorites.endpointLabel}',
      );
    }

    return PagedPostList(
      controller: _favorites,
      scrollController: _scroll,
      tracker: _tracker,
      header: _favorites.fromCache && _favorites.cachedAt != null
          ? _cacheHint()
          : null,
      itemBuilder: (context, post, index) => PostCard(
        post: post,
        isRead: _favorites.isReadAt(index),
        isFavourite: true,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => PostDetailPage(post: post)),
        ),
        onCollectionTap: () => openCollectionOfPost(context, post),
        onVote: (target) async {
          final ok = await toggleVote(context, post);
          if (ok) _favorites.applyVote(post.id, post.isVoted);
        },
        onFavourite: (target) async {
          final ok = await removeFavourite(context, post.id);
          if (!ok) return;
          // 删除前先请列表记下参考条目并预跳偏移（必须先于改数据，同一帧内
          // 完成）。否则被删条目下方的内容会整段位移 —— 展开成长文后取消
          // 收藏时尤其明显（2026-09-22 用户报「窗口会跳跃」）。
          PagedPostListAnchor.removalOf(context)?.call(post.id);
          _favorites.removePost(post.id);
        },
      ),
    );
  }

  /// 数据来自本地缓存时的提示条。
  Widget _cacheHint() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
      color: AppTheme.infoBackground,
      child: Row(
        children: [
          Icon(Icons.offline_bolt_outlined,
              size: 13, color: AppTheme.accent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '内容来自本地缓存（抓取于 ${timeAgo(_favorites.cachedAt!)}）',
              style: TextStyle(fontSize: 11.5, color: AppTheme.accent),
            ),
          ),
          Text(
            '下拉可刷新',
            style: TextStyle(fontSize: 11, color: AppTheme.inkTertiary),
          ),
        ],
      ),
    );
  }
}
