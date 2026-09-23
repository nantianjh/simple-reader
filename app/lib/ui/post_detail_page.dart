import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/api_config.dart';
import '../api/api_exception.dart';
import '../api/models.dart';
import '../api/simple_api.dart';
import '../state/app_scope.dart';
import '../util/format.dart';
import 'actions.dart';
import 'collection_detail_page.dart';
import 'theme.dart';
import 'user_profile_page.dart';
import 'widgets/brightness_aware.dart';
import 'widgets/emoji_panel.dart';
import 'widgets/link_chip.dart';
import 'widgets/linkified_text.dart';
import 'widgets/media_grid.dart';
import 'widgets/pending_emoji_strip.dart';
import 'widgets/state_views.dart';
import 'widgets/user_avatar.dart';

/// 内容详情页：完整正文 + 媒体 + 评论区。
class PostDetailPage extends StatefulWidget {
  const PostDetailPage({
    super.key,
    required this.post,
  });

  final Post post;

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  final SimpleApi _api = SimpleApi();
  final TextEditingController _commentInput = TextEditingController();
  final FocusNode _commentFocus = FocusNode();

  final List<Comment> _comments = [];
  String? _cursor;
  bool _hasMore = false;
  bool _loading = false;
  bool _sending = false;
  String? _error;

  /// 当前回复目标。null = 发表主评论；非空 = 回复该条（或楼层）。
  Comment? _replyTarget;

  /// 待随评论发送的表情。评论里的表情不是文本：按官方形态作为
  /// media 图片项（{type:"image", url}）随 body 一起发送。
  final List<Emoji> _pendingEmojis = [];

  /// 表情面板展开态。输入框获得焦点时自动收起（与键盘互斥）。
  bool _emojiPanelOpen = false;

  /// 已展开到全量的回复（key = 主评论 id）。
  /// preview_replies 通常只有 3 条，点「查看全部回复」后从
  /// `comments/replies` 端点分页拉取，替换展示列表。
  final Map<String, List<Comment>> _expandedReplies = {};
  final Map<String, String> _replyCursors = {};
  final Map<String, bool> _replyHasMore = {};
  final Set<String> _replyLoading = {};

  @override
  void initState() {
    super.initState();
    _loadComments(first: true);
    // 键盘与表情面板互斥：聚焦输入框时收起面板。
    _commentFocus.addListener(() {
      if (_commentFocus.hasFocus && _emojiPanelOpen && mounted) {
        setState(() => _emojiPanelOpen = false);
      }
    });
  }

  @override
  void dispose() {
    _commentInput.dispose();
    _commentFocus.dispose();
    super.dispose();
  }

  /// [mode] 控制缓存策略：常规进入用缓存优先；发表评论后的刷新必须强制
  /// 走网络——否则 `_fetchWithCache` 会命中本地缓存的评论页，新评论不显示。
  Future<void> _loadComments({
    required bool first,
    CacheMode mode = CacheMode.preferCache,
  }) async {
    final app = AppScope.read(context);
    final token = app.token;
    if (token == null || token.isEmpty) return;
    if (_loading) return;

    setState(() {
      _loading = true;
      if (first) _error = null;
    });

    try {
      final page = await _api.fetchComments(
        postId: widget.post.id,
        token: token,
        lastId: first ? '' : (_cursor ?? ''),
        mode: mode,
      );
      if (!mounted) return;
      setState(() {
        if (first) _comments.clear();
        _comments.addAll(page.items);
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.requiresReauth) app.markUnauthorized(e.message);
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载评论失败：$e';
        _loading = false;
      });
    }
  }

  Future<void> _sendComment() async {
    final text = _commentInput.text.trim();
    final emojis = List<Emoji>.of(_pendingEmojis);
    if (text.isEmpty && emojis.isEmpty) return;
    final app = AppScope.read(context);
    final token = app.token;
    if (token == null || token.isEmpty) return;

    final target = _replyTarget;
    setState(() => _sending = true);
    try {
      if (target == null) {
        await _api.createComment(
          postId: widget.post.id,
          content: text,
          media: emojis,
          token: token,
        );
      } else {
        await _api.replyComment(
          commentId: target.id,
          content: text,
          media: emojis,
          token: token,
        );
      }
      if (!mounted) return;
      _commentInput.clear();
      setState(() {
        _pendingEmojis.clear();
        _replyTarget = null;
        _emojiPanelOpen = false;
      });
      _commentFocus.unfocus();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(target == null ? '评论已发布' : '回复已发送')),
        );
      // 刷新必须绕过评论缓存，否则刚发的评论不会出现（缓存未过期时
      // preferCache 会直接命中本地，不发网络请求）。展开过的回复列表
      // 也一并作废，让刷新后的 preview_replies 重新给出。
      _expandedReplies.clear();
      _replyCursors.clear();
      _replyHasMore.clear();
      await _loadComments(first: true, mode: CacheMode.networkFirst);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.requiresReauth) app.markUnauthorized(e.message);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('发布失败：$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ---------------------------------------------------------- 评论互动

  /// 挑选 / 取消一个待发表情。
  void _togglePendingEmoji(Emoji emoji) {
    setState(() {
      final i = _pendingEmojis.indexWhere((e) => e.id == emoji.id);
      if (i >= 0) {
        _pendingEmojis.removeAt(i);
      } else {
        _pendingEmojis.add(emoji);
      }
    });
  }

  /// 把某条评论设为回复目标（主评论与回复楼层通用）。
  void _startReply(Comment c) {
    setState(() {
      _replyTarget = c;
      _emojiPanelOpen = false;
    });
    _commentFocus.requestFocus();
  }

  /// 拉全量回复：首页替换 preview 列表，后续按游标追加。
  Future<void> _expandReplies(Comment c) async {
    final app = AppScope.read(context);
    final token = app.token;
    if (token == null || token.isEmpty || _replyLoading.contains(c.id)) return;

    setState(() => _replyLoading.add(c.id));
    try {
      final lastId = _replyCursors[c.id] ?? '';
      final page = await _api.fetchCommentReplies(
        commentId: c.id,
        token: token,
        lastId: lastId,
      );
      if (!mounted) return;
      setState(() {
        final list = _expandedReplies.putIfAbsent(c.id, () => <Comment>[]);
        // 首页（无游标）替换 preview；后续追加，并按 id 去重。
        final known = {for (final r in list) r.id};
        for (final r in page.items) {
          if (known.add(r.id)) list.add(r);
        }
        _replyCursors[c.id] = page.nextCursor ?? '';
        _replyHasMore[c.id] = page.hasMore;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.requiresReauth) app.markUnauthorized(e.message);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('回复加载失败：$e')));
    } finally {
      if (mounted) setState(() => _replyLoading.remove(c.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    // 包一层亮度依赖：详情页配色全是静态语义色，不重建就会停在旧主题
    //（本页是 push 出来的路由，父级不会带它 rebuild）。
    return BrightnessAware(builder: (context, _) => _contents());
  }

  Widget _contents() {
    final post = widget.post;
    return Scaffold(
      backgroundColor: AppTheme.pageBackground,
      // 键盘 insets 由评论栏自己接管（见 _commentBar 的 padding）：不再
      // 依赖系统 resize 行为——Android 15 edge-to-edge 下 adjustResize 与
      // inset 分发在部分机型上表现不稳，曾出现长文本输入被键盘遮住。
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('内容详情'),
        actions: [
          IconButton(
            tooltip: '在 Simple 中打开',
            onPressed: () =>
                openInSimple(context, ApiConfig.sharePostUrl(post.id)),
            icon: const Icon(Icons.open_in_new_rounded, size: 19),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 20),
              children: [
                _postSection(post),
                const SizedBox(height: 8),
                _commentSection(),
              ],
            ),
          ),
          _commentBar(),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 正文

  Widget _postSection(Post post) {
    return Container(
      color: AppTheme.cardBackground,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 点作者头像进入 TA 的主页（自己的头像不跳）。
              InkWell(
                onTap: () {
                  final me = AppScope.read(context).currentUser?.id;
                  final uid = post.user.id;
                  if (uid.isEmpty) return;
                  if (me != null && me.isNotEmpty && me == uid) return;
                  openUserProfile(context,
                      userId: uid, nickname: post.user.nickname);
                },
                customBorder: const CircleBorder(),
                child: UserAvatar(user: post.user, size: 42),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            post.user.nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.inkPrimary,
                            ),
                          ),
                        ),
                        if (post.user.isOfficial) ...[
                          const SizedBox(width: 5),
                          Icon(Icons.verified_rounded,
                              size: 14, color: AppTheme.accent),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      formatDateTime(post.createdAt),
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.inkTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (post.postCollection != null) ...[
            const SizedBox(height: 12),
            InkWell(
              onTap: () => openCollectionOfPost(context, post),
              borderRadius: BorderRadius.circular(7),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: AppTheme.accentMutedBg,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.collections_bookmark_rounded,
                        size: 14, color: AppTheme.accent),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        post.postCollection!.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppTheme.accent,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '查看合集',
                      style: TextStyle(fontSize: 11.5, color: AppTheme.accent),
                    ),
                    Icon(Icons.chevron_right_rounded,
                        size: 14, color: AppTheme.accent),
                  ],
                ),
              ),
            ),
          ],
          if (post.hasText) ...[
            const SizedBox(height: 14),
            // 保留长按复制能力，同时把正文里的链接变成可点击项。
            LinkifiedText(
              text: post.content,
              selectable: true,
              style: TextStyle(
                fontSize: 15,
                color: AppTheme.inkPrimary,
                height: 1.72,
              ),
            ),
          ],
          if (post.hasCardLinks) ...[
            const SizedBox(height: 12),
            for (final url in post.cardLinks) ...[
              LinkChip(url: url),
              if (url != post.cardLinks.last) const SizedBox(height: 7),
            ],
          ],
          if (post.media.isNotEmpty) ...[
            const SizedBox(height: 14),
            MediaGrid(media: post.media, maxVisible: 18),
          ],
          const SizedBox(height: 16),
          const Divider(height: 0.6),
          const SizedBox(height: 6),
          Row(
            children: [
              _actionChip(
                icon: post.isVoted
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                label: post.votesCount == null
                    ? (post.isVoted ? '已赞' : '点赞')
                    : '${compactCount(post.votesCount!)} 赞',
                active: post.isVoted,
                activeColor: AppTheme.likeColor,
                onTap: () async {
                  final ok = await toggleVote(context, post);
                  if (ok && mounted) setState(() {});
                },
              ),
              const SizedBox(width: 8),
              _actionChip(
                icon: post.isFavourited
                    ? Icons.star_rounded
                    : Icons.star_border_rounded,
                label: post.isFavourited ? '已收藏' : '收藏',
                active: post.isFavourited,
                activeColor: AppTheme.starColor,
                onTap: () async {
                  final ok = await toggleFavourite(context, post);
                  if (ok && mounted) setState(() {});
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionChip({
    required IconData icon,
    required String label,
    required bool active,
    Color? activeColor,
    required VoidCallback onTap,
  }) {
    final ac = activeColor ?? AppTheme.accent;
    final color = active ? ac : AppTheme.inkSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active
              ? ac.withValues(alpha: 0.08)
              : AppTheme.surfaceMuted,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: color,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 评论

  Widget _commentSection() {
    return Container(
      color: AppTheme.cardBackground,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '评论',
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.inkPrimary,
                ),
              ),
              const SizedBox(width: 6),
              if (widget.post.commentsCount > 0)
                Text(
                  '${widget.post.commentsCount}',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.inkTertiary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (_loading && _comments.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: LoadingView(),
            )
          else if (_error != null && _comments.isEmpty)
            ErrorView(
              message: _error!,
              onRetry: () => _loadComments(first: true),
            )
          else if (_comments.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  '还没有评论',
                  style: TextStyle(fontSize: 13, color: AppTheme.inkTertiary),
                ),
              ),
            )
          else ...[
            for (final c in _comments) _commentTile(c),
            if (_hasMore)
              Center(
                child: TextButton(
                  onPressed: _loading ? null : () => _loadComments(first: false),
                  child: Text(_loading ? '加载中…' : '加载更多评论'),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _commentTile(Comment c) {
    // 点过「查看全部回复」的评论用全量列表，否则用 preview_replies。
    final replies = _expandedReplies[c.id] ?? c.replies;
    final hidden = c.repliesCount - replies.length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _commentRow(c),
          // 回复楼层：preview_replies（前几条）或展开后的全量列表。
          if (replies.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              margin: const EdgeInsets.only(left: 39),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
              decoration: BoxDecoration(
                color: AppTheme.surfaceAlt,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final r in replies)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: _commentRow(r, compact: true, parent: c),
                    ),
                  if (hidden > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: InkWell(
                        onTap: _replyLoading.contains(c.id)
                            ? null
                            : () => _expandReplies(c),
                        borderRadius: BorderRadius.circular(5),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 3, vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_replyLoading.contains(c.id)) ...[
                                const SizedBox(
                                  width: 11,
                                  height: 11,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 1.4),
                                ),
                                const SizedBox(width: 5),
                              ],
                              Text(
                                replies.isEmpty
                                    ? '查看全部 ${c.repliesCount} 条回复'
                                    : '还有 $hidden 条回复未展示',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: AppTheme.accent,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 「作者」标识。作者本人出现在评论区时用，避免读者把作者回复当普通路人回复。
  Widget _authorBadge({required bool compact}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
      decoration: BoxDecoration(
        color: AppTheme.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(4),
        border:
            Border.all(color: AppTheme.accent.withValues(alpha: 0.28), width: 0.6),
      ),
      child: Text(
        '作者',
        style: TextStyle(
          fontSize: compact ? 9.5 : 10,
          color: AppTheme.accent,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
      ),
    );
  }

  Widget _commentRow(Comment c, {bool compact = false, Comment? parent}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 点评论者头像进入 TA 的主页（自己的头像不跳）。
        InkWell(
          onTap: () {
            final me = AppScope.read(context).currentUser?.id;
            final uid = c.user.id;
            if (uid.isEmpty) return;
            if (me != null && me.isNotEmpty && me == uid) return;
            openUserProfile(context,
                userId: uid, nickname: c.user.nickname);
          },
          customBorder: const CircleBorder(),
          child: UserAvatar(user: c.user, size: compact ? 24 : 30),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      c.user.nickname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 12.5 : 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.inkSecondary,
                      ),
                    ),
                  ),
                  // 作者本人的评论加标识（优先用服务端给的 is_author，
                  // 没给时退回本地比对动态作者）。
                  if (_isAuthor(c)) ...[
                    const SizedBox(width: 5),
                    _authorBadge(compact: compact),
                  ],
                  const SizedBox(width: 8),
                  Text(
                    timeAgo(c.createdAt),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.inkTertiary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // 「回复 @某人」：接口通过 replied_user 告知被回复人。
              // 注意：回复他人评论时 POST 响应里该字段为 null（服务端
              // 未回填），展示依赖刷新后服务端补出的数据。
              if (c.repliedUser != null &&
                  c.repliedUser!.nickname.isNotEmpty &&
                  (parent == null || c.repliedUser!.id != parent.user.id))
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '回复 @${c.repliedUser!.nickname}',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.accent,
                    ),
                  ),
                ),
              LinkifiedText(
                text: c.content,
                style: TextStyle(
                  fontSize: compact ? 13 : 14,
                  color: AppTheme.inkPrimary,
                  height: 1.55,
                ),
              ),
              // 评论里的表情/图片：官方把表情作为 media 图片项随评论
              // 一起发送（content 是纯文本）。渲染必须走类型判定
              // （MediaThumb 与动态九宫格共用）：实况照片（.mov/.heic
              // 地址或 type=live）直接喂给 NetImage 会是破图。
              if (c.media.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final m in c.media)
                      // 需求（2026-09-22 #8）：评论里的图片要能和动态图片一样
                      // 点开查看（捏合缩放/平移/切页/保存相册）与长按保存 ——
                      // 复用 MediaGrid 的同一套判定与查看器。浏览范围传**这条
                      // 评论自己的媒体**，查看器里就只在这条评论的图之间翻，
                      // 不会串到动态正文或其他评论的图。
                      GestureDetector(
                        onTap: () => MediaGrid.handleTap(context, c.media, m),
                        onLongPress: () =>
                            MediaGrid.handleLongPress(context, m),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: MediaThumb(media: m, size: 56),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        // 右缘动作列：回复 + 点赞。
        const SizedBox(width: 6),
        _commentActions(c, compact: compact),
      ],
    );
  }

  /// 评论者是否为这条动态的作者本人。
  bool _isAuthor(Comment c) {
    if (c.isAuthor) return true;
    final authorId = widget.post.user.id;
    return authorId.isNotEmpty && c.user.id.isNotEmpty && c.user.id == authorId;
  }

  /// 评论行的右缘动作：回复 + 点赞。
  ///
  /// 点赞数只在**自己的评论**上显示（服务端只对 is_owner=true 下发
  /// votes_count，他人评论拿不到计数——这是用户明确不需要的能力，
  /// 他人评论只渲染"已赞/未赞"状态）。
  Widget _commentActions(Comment c, {required bool compact}) {
    final n = c.votesCount;
    final showCount = c.isOwner && n != null && n > 0;
    final color = c.isVoted ? AppTheme.likeColor : AppTheme.inkTertiary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        InkWell(
          onTap: () => _startReply(c),
          borderRadius: BorderRadius.circular(5),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Icon(
              Icons.mode_comment_outlined,
              size: compact ? 14 : 15,
              color: AppTheme.inkTertiary,
            ),
          ),
        ),
        const SizedBox(height: 2),
        InkWell(
          onTap: () async {
            final ok = await toggleCommentVote(context, c);
            if (ok && mounted) setState(() {});
          },
          borderRadius: BorderRadius.circular(5),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  c.isVoted
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  size: compact ? 14 : 16,
                  color: color,
                ),
                if (showCount)
                  Text(
                    compactCount(n),
                    style: TextStyle(fontSize: 10, color: color),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _commentBar() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        border: Border(top: BorderSide(color: AppTheme.divider, width: 0.6)),
      ),
      // 手动接管键盘 insets（Scaffold 已设 resizeToAvoidBottomInset:false，
      // viewInsets 会原样传到 body）：键盘弹出时输入条精确浮在键盘上方；
      // 收起时补导航条高度。取 max 而不是相加——键盘弹出时系统会把
      // padding.bottom 归零，但个别 ROM 口径不一，max 可避免双算。
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        top: 8,
        bottom: 8 +
            math.max(
              MediaQuery.of(context).viewInsets.bottom,
              MediaQuery.of(context).padding.bottom,
            ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 四个槽位都有条件出现（回复条 / 待发条 / 表情面板 / 输入行），
          // 必须都挂 Key：否则点第一个表情插入「待发条」时子项索引整体
          // 位移，Flutter 按位置配对会把表情面板误认成别的槽位重建，
          // 表现成"点完表情面板立即重刷新一次"。挂 Key 后按 key 配对，
          // EmojiPanel 的 State（含已加载的表情缓存）完整保留。
          if (_replyTarget != null)
            KeyedSubtree(key: ValueKey('reply-target'), child: _replyingBar()),
          if (_pendingEmojis.isNotEmpty)
            KeyedSubtree(
              key: ValueKey('pending-emojis'),
              child: PendingEmojiStrip(
                emojis: _pendingEmojis,
                onRemove: _togglePendingEmoji,
              ),
            ),
          if (_emojiPanelOpen)
            KeyedSubtree(
              key: ValueKey('emoji-panel'),
              child: Container(
                height: 235,
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: AppTheme.cardBackground,
                  border: Border(
                      top: BorderSide(color: AppTheme.divider, width: 0.6)),
                ),
                child: EmojiPanel(
                  pickedIds: {for (final e in _pendingEmojis) e.id},
                  onPick: _togglePendingEmoji,
                ),
              ),
            ),
          KeyedSubtree(
            key: ValueKey('input-row'),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _commentInput,
                    focusNode: _commentFocus,
                    // 多行自适应：1~6 行，换行自动长高，超过后框内滚动。
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    minLines: 1,
                    maxLines: 6,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: _replyTarget == null
                          ? '说点什么…'
                          : '回复 @${_replyTarget!.user.nickname}…',
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 11),
                    ),
                  ),
                ),
                // 表情入口在输入框右侧、发送键左边。
                IconButton(
                  onPressed: () =>
                      setState(() => _emojiPanelOpen = !_emojiPanelOpen),
                  icon: Icon(
                    _emojiPanelOpen
                        ? Icons.emoji_emotions_rounded
                        : Icons.emoji_emotions_outlined,
                    size: 23,
                  ),
                  color:
                      _emojiPanelOpen ? AppTheme.accent : AppTheme.inkTertiary,
                  tooltip: '表情',
                  visualDensity: VisualDensity.compact,
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 2, bottom: 1),
                  child: FilledButton(
                    onPressed: _sending ? null : _sendComment,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 42),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    child: _sending
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(_replyTarget == null ? '发送' : '回复'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 回复目标条：提示在回复谁，可取消。
  Widget _replyingBar() {
    final t = _replyTarget!;
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.fromLTRB(10, 5, 5, 5),
      decoration: BoxDecoration(
        color: AppTheme.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '回复 @${t.user.nickname}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: AppTheme.inkSecondary,
              ),
            ),
          ),
          InkWell(
            onTap: () => setState(() => _replyTarget = null),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close_rounded,
                  size: 15, color: AppTheme.inkTertiary),
            ),
          ),
        ],
      ),
    );
  }
}
