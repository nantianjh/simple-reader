import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/simple_api.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../state/collections_state.dart';
import '../state/load_phase.dart';
import 'actions.dart';
import 'post_detail_page.dart';
import 'theme.dart';
import 'widgets/brightness_aware.dart';
import 'widgets/paged_post_list.dart';
import 'widgets/post_card.dart';
import 'widgets/read_tracker.dart';
import 'widgets/remark_name.dart';
import 'widgets/state_views.dart';

/// 从一条动态的「所属合集」标签进入合集详情页的统一入口。
///
/// 合集内容必须按 **作者 + 合集** 双参数过滤（见
/// [SimpleApi.fetchCollectionPosts]），而合集作者最可靠的来源就是这条动态的
/// 作者 —— 内嵌的 `post_collection` 对象在 v2 只有 4 个字段（不带 `user_id`）。
/// 所以这里把 post 的作者一并带进去。
Future<void> openCollectionOfPost(BuildContext context, Post post) async {
  final c = post.postCollection;
  if (c == null || c.id.isEmpty) return;
  final app = AppScope.read(context);
  final authorId = c.userId.isNotEmpty ? c.userId : post.user.id;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CollectionDetailPage(
        collection: c,
        authorId: authorId,
        authorName: post.user.nickname,
        ownerUserId: app.currentUser?.id ?? app.jwt?.userId ?? '',
      ),
    ),
  );
}

/// 合集详情：展示某个合集内的动态。
///
/// 取数分两步（探查报告第十节实测链路）：
/// 1. 头部：`GET api/v3/post_collections/{id}` → 条数 / 作者 / 我是否收藏；
/// 2. 内容：`GET api/v2/posts/profile?user_id=<作者>&post_collection_id=<合集>`
///    （自己的合集走 `posts/mine`），翻页与续读复用分页式瀑布流。
class CollectionDetailPage extends StatefulWidget {
  const CollectionDetailPage({
    super.key,
    required this.collection,
    this.authorId = '',
    this.authorName = '',
    this.ownerUserId = '',
  });

  final PostCollection collection;

  /// 合集作者 ID。来自收录它的那条动态的作者。
  final String authorId;

  /// 作者昵称，仅用于展示（可缺失）。
  final String authorName;

  /// 当前登录用户 ID（由调用方传入，避免在 build 里重复取）。
  final String ownerUserId;

  @override
  State<CollectionDetailPage> createState() => _CollectionDetailPageState();
}

class _CollectionDetailPageState extends State<CollectionDetailPage> {
  final ScrollController _scroll = ScrollController();
  final SimpleApi _api = SimpleApi();
  late CollectionPostsController _posts;
  late final ItemVisibilityTracker _tracker;

  /// 头部元信息（v3 单条接口返回后回填）。
  PostCollection? _meta;
  bool _metaLoading = false;
  bool _metaFailed = false;

  /// 实际用于查询的作者 id：优先用 v3 单条接口给出的 `user_id`。
  String _resolvedAuthorId = '';

  bool get _mine {
    final me = widget.ownerUserId;
    return me.isNotEmpty && me == _resolvedAuthorId;
  }

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    _tracker = ItemVisibilityTracker(_scroll);
    _resolvedAuthorId = widget.authorId;
    _posts = _createPosts(app);

    // 没有作者信息时不发内容请求，等 v3 单条接口把作者补出来（见 _loadMeta）。
    if (widget.authorId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _posts.ensureLoaded();
      });
    }
    _loadMeta();
  }

  CollectionPostsController _createPosts(AppState app) =>
      CollectionPostsController(
        tokenProvider: () => app.token,
        collectionId: widget.collection.id,
        authorId: _resolvedAuthorId,
        mine: _mine,
      )..onAuthFailure = (msg) {
          if (mounted) app.markUnauthorized(msg);
        };

  @override
  void dispose() {
    _scroll.dispose();
    _posts.dispose();
    super.dispose();
  }

  /// 头部元信息：v3 单条合集接口。失败不阻断内容，只是少显示条数与收藏态。
  Future<void> _loadMeta() async {
    final app = AppScope.read(context);
    final token = app.token;
    if (token == null || token.isEmpty || widget.collection.id.isEmpty) {
      setState(() => _metaFailed = true);
      return;
    }
    setState(() => _metaLoading = true);
    try {
      final meta = await _api.fetchCollectionMeta(
        token: token,
        collectionId: widget.collection.id,
      );
      if (!mounted) return;

      // 调用方没带作者信息时，用头部接口补出作者再加载内容。
      final needAuthor = _resolvedAuthorId.isEmpty;
      if (needAuthor && meta != null && meta.userId.isNotEmpty) {
        _resolvedAuthorId = meta.userId;
        _posts.dispose();
        _posts = _createPosts(app);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _posts.ensureLoaded();
        });
      }

      setState(() {
        _meta = meta;
        _metaLoading = false;
        _metaFailed = meta == null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _metaLoading = false;
        _metaFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 包一层亮度依赖：本页配色全是静态语义色，不重建就会停在旧主题。
    return BrightnessAware(builder: (context, _) => _contents(context));
  }

  Widget _contents(BuildContext context) {
    final app = AppScope.of(context);
    final c = _meta ?? widget.collection;

    return Scaffold(
      backgroundColor: AppTheme.pageBackground,
      appBar: AppBar(
        title: Text(c.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '重新拉取',
            onPressed: _posts.busy ? null : () => _posts.refresh(),
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _header(c),
            if (app.status == AuthStatus.invalid && app.errorMessage != null)
              AuthBanner(message: app.errorMessage!),
            Expanded(
              child: AnimatedBuilder(
                animation: _posts,
                builder: (context, _) => _body(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 合集信息条：条数 + 收藏态 + 作者 + 简介。
  Widget _header(PostCollection c) {
    final count = c.postsCount >= 0 ? '${c.postsCount} 条内容' : '合集内容';
    final author =
        c.creator.nickname.isNotEmpty ? c.creator.nickname : widget.authorName;
    // 作者 id：优先取头部接口给的 creator.id，没有就退回"收录它那条动态的作者"。
    final authorId =
        c.creator.id.isNotEmpty ? c.creator.id : widget.authorId;

    return Container(
      width: double.infinity,
      color: AppTheme.cardBackground,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  count,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.inkSecondary,
                  ),
                ),
              ),
              if (c.isFavourited)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: AppTheme.warningBackground,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '我收藏的合集',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTheme.warning,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (_metaLoading) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              if (author.isNotEmpty) ...[
                Icon(Icons.person_outline_rounded,
                    size: 13, color: AppTheme.inkTertiary),
                const SizedBox(width: 4),
                Flexible(
                  // 合集作者名也套本地备注（作者 id 拿得到就一定对上）。
                  child: RemarkedText(
                    nickname: author,
                    userId: authorId,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.inkTertiary,
                    ),
                  ),
                ),
              ],
              if (_metaFailed) ...[
                const SizedBox(width: 10),
                Text(
                  '未取到合集头部信息',
                  style: TextStyle(fontSize: 11.5, color: AppTheme.warning),
                ),
              ],
            ],
          ),
          if (c.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              c.description,
              style: TextStyle(
                fontSize: 12.5,
                color: AppTheme.inkTertiary,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _body() {
    if (_resolvedAuthorId.isEmpty) {
      return ErrorView(
        message: '这条合集记录里没有作者信息，无法查询合集内容。\n'
            '合集内容按「作者 + 合集」双参数过滤，请从动态卡片上的合集标签进入。'
            '${_metaLoading ? '\n正在尝试从服务端补出作者…' : ''}',
        onRetry: _loadMeta,
      );
    }
    if (_posts.phase == LoadPhase.loadingFirst && _posts.posts.isEmpty) {
      return const LoadingView(message: '正在拉取合集内容…');
    }
    if (_posts.phase == LoadPhase.error && _posts.posts.isEmpty) {
      return ErrorView(
        message: _posts.error ?? '加载失败',
        onRetry: _posts.retry,
      );
    }
    if (_posts.isEmptyResult) {
      return EmptyView(
        icon: Icons.inbox_outlined,
        title: '这个合集里还没有内容',
        subtitle: '当前取数口径：${_posts.paramLabel}\n'
            '若合集本身有内容而这里为空，说明服务端的过滤参数与客户端不一致。',
      );
    }

    return PagedPostList(
      controller: _posts,
      scrollController: _scroll,
      tracker: _tracker,
      // 这里的每一条本来就属于当前合集，标签只作展示，不再重复入栈。
      itemBuilder: (context, post, index) => PostCard(
        post: post,
        isRead: _posts.isReadAt(index),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => PostDetailPage(post: post)),
        ),
        onVote: (target) async {
          final ok = await toggleVote(context, post);
          if (ok) _posts.applyVote(post.id, post.isVoted);
        },
        onFavourite: (target) async {
          final ok = await toggleFavourite(context, post);
          if (ok) _posts.applyFavourite(post.id, post.isFavourited);
        },
      ),
    );
  }
}
