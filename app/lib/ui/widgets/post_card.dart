import 'package:flutter/material.dart';

import '../../api/api_config.dart';
import '../../api/api_exception.dart';
import '../../api/models.dart';
import '../../api/simple_api.dart';
import '../../data/settings.dart';
import '../../data/vote_overlay.dart';
import '../../data/vote_states.dart';
import '../../state/app_scope.dart';
import '../../util/app_log.dart';
import '../../util/format.dart';
import '../actions.dart';
import '../theme.dart';
import '../user_profile_page.dart';
import 'emoji_panel.dart';
import 'link_chip.dart';
import 'linkified_text.dart';
import 'media_grid.dart';
import 'paged_post_list.dart';
import 'pending_emoji_strip.dart';
import 'remark_name.dart';
import 'user_avatar.dart';
import 'vote_state_bar.dart';

/// 内容帖卡片。
///
/// 列表里承担主要信息密度：作者、时间、所属合集、正文、媒体、互动入口。
///
/// 正文里的链接会被渲染成可点击文本，服务端转成「卡片」的链接会以链接条
/// 的形式补在正文下方——客户端不做卡片还原。
///
/// 与正文长度相关的本地交互（均为卡片自身状态，不影响列表结构，
/// 因此展开/收起都发生在瀑布流原位）：
/// * 超过 6 行的正文默认折叠：折叠态在正文第六行下方居中显示
///   「−请展开阅读−」（点击展开），按钮栏里另有「展开全文 / 收起」；
/// * 整条动态可「折叠」成一行摘要：底部按钮，或**双指捏合卡片**
///   （点开图片之前就会响应）；折叠后单击卡片可还原。
///
/// 点「评论」按钮会在卡片下方**原位展开快捷评论条**（不进详情页，
/// 网页微博式）：输入 + 表情随评，发送走与详情页同一套评论接口。
///
/// 长按「点赞」按钮在**同一个位置**展开一条**表态条**（理解 / 支持 /
/// 加油 / 安慰 …），选中即送出，并把那个态度回显在按钮上 —— 官方 App 里
/// 那条"可扩展点赞条"在本机的对应物（可送出的状态表见
/// `data/vote_states.dart`）。形态刻意与快捷评论条同构：不用弹层、不用
/// Overlay，高度变化照旧走 [PagedPostListAnchor] 锚定，不引入第二种
/// 定位机制。
///
/// 高度变化会让 `ListView` 里下方内容整体位移（观感是"画面猛地一跳"），
/// 因此每次改变自身高度前都会通过 [PagedPostListAnchor] 请列表记下锚点，
/// 布局完成后再把锚点放回原位 —— 这也是"跳跃"类问题的日志来源。
class PostCard extends StatefulWidget {
  const PostCard({
    super.key,
    required this.post,
    this.onTap,
    this.onVote,
    this.onFavourite,
    this.onCollectionTap,
    this.isFavourite,
    this.isRead = false,
    this.showActions = true,
  });

  final Post post;
  final VoidCallback? onTap;

  /// 点赞回调。传入期望的目标状态。
  final void Function(bool on)? onVote;

  /// 收藏回调。传 null 表示该位置不展示收藏按钮。
  final void Function(bool on)? onFavourite;

  /// 点击「所属合集」标签的回调。传 null 时标签只展示不可点。
  final VoidCallback? onCollectionTap;

  /// 外部已知的收藏态（收藏页列表为 true）。
  final bool? isFavourite;

  /// 是否已被完整读过（续读点之前的内容）。
  final bool isRead;

  final bool showActions;

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  /// 正文折叠行数与正文样式（溢出预判与实际渲染必须用同一份，否则会出现
  /// "预判溢出了但实际没溢出"之类的按钮闪现）。AppTheme 的颜色是随明暗
  /// 切换的 getter，样式只能做成 getter 而非常量。
  static const int _maxContentLines = 6;
  static TextStyle get _contentStyle => TextStyle(
        fontSize: 14.5,
        height: 1.6,
        color: AppTheme.inkPrimary,
      );

  /// 正文是否已展开（超过 6 行时默认折叠）。
  bool _textExpanded = false;

  /// 整条动态是否被用户折叠。
  bool _collapsed = false;

  Post get post => widget.post;

  // ------------------------------------------------------------ 内联表态条

  /// 表态条展开态（长按点赞按钮开关）。
  ///
  /// 与快捷评论条**互斥**：两条同时摊开会让卡片一下子高出一大截，在这套
  /// 对高度变化敏感的列表里不划算 —— 展开一条就收起另一条。
  bool _voteBarOpen = false;

  // ------------------------------------------------------------ 内联评论条

  /// 快捷评论条展开态（feed 内不进详情直接评论，网页微博式）。
  bool _composerOpen = false;

  /// 表情面板展开态。与输入框焦点互斥（聚焦时自动收起）。
  bool _composerEmojiOpen = false;

  /// 待随评论发送的表情。评论里的表情不是文本：按官方形态作为
  /// media 图片项（{type:"image", url}）随 body 一起发送。
  final List<Emoji> _pendingEmojis = [];

  final TextEditingController _composerInput = TextEditingController();
  final FocusNode _composerFocus = FocusNode();

  /// 发送中标记（按钮转圈 + 防重复提交）。
  bool _sendingComment = false;

  /// 本实例存续期内已成功发出的评论数。[Post.commentsCount] 是 final，
  /// 用本地增量让按钮数字即时 +1；重新拉取数据后以服务端为准。
  int _sentComments = 0;

  @override
  void initState() {
    super.initState();
    // 键盘与表情面板互斥：聚焦输入框时收起面板（与详情页评论栏同口径）。
    _composerFocus.addListener(() {
      if (_composerFocus.hasFocus && _composerEmojiOpen && mounted) {
        setState(() => _composerEmojiOpen = false);
      }
    });
  }

  @override
  void dispose() {
    _composerInput.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  /// 通知外层列表：本卡片的高度即将变化，请先记住滚动锚点。
  ///
  /// [willShrink] 告诉列表这次是收缩（折叠整条 / 收起正文）还是撑高，
  /// 连同本条 id 一起传——长文浏览到中部时折叠整条，列表要靠"发起条目
  /// 就是锚点条目"这个判断把折叠摘要收回到视口顶端。
  void _anchorHeightChange(bool willShrink) =>
      PagedPostListAnchor.maybeOf(context)?.call(willShrink, post.id);

  /// 展开 / 收起正文。属于本卡片内部的高度变化。
  void _toggleTextExpanded() {
    final willExpand = !_textExpanded;
    _anchorHeightChange(!willExpand);
    log.d(
      LogTag.ui,
      '正文${willExpand ? '展开' : '收起'}：${post.id}'
      '（${post.content.length} 字）',
    );
    setState(() => _textExpanded = willExpand);
  }

  /// 折叠 / 还原整条动态。按钮与双指捏合共用。
  void _setCollapsed(bool value) {
    if (_collapsed == value) return;
    _anchorHeightChange(value);
    log.i(LogTag.ui, '${value ? '折叠' : '展开'}整条动态：${post.id}');
    setState(() => _collapsed = value);
  }

  // ---------------------------------------------------------- 内联表态交互

  /// 长按点赞按钮：原位展开 / 收起表态条。
  ///
  /// 长按本身**不动点赞态** —— 真送出发生在选中一项之后（[_sendVoteState]），
  /// 所以展开又收起不会留下任何痕迹。高度变化照旧先锚定（与评论条同一套）。
  void _toggleVoteBar() {
    final willOpen = !_voteBarOpen;
    _anchorHeightChange(!willOpen);
    log.d(LogTag.ui, '${willOpen ? '展开' : '收起'}表态条：${post.id}');
    setState(() {
      _voteBarOpen = willOpen;
      if (willOpen && _composerOpen) {
        // 与评论条互斥（见 [_voteBarOpen] 的说明）。
        _composerOpen = false;
        _composerEmojiOpen = false;
        _composerFocus.unfocus();
      }
    });
  }

  /// 选中一个表态：先收起条，再送出。
  ///
  /// 先收再送：成功不会弹提示，按钮上的回显（表情 + 短名）就是反馈，
  /// 条没必要赖在卡片里；失败了也不重开 —— 错误提示会说明原因
  /// （见 [sendVoteState]）。
  Future<void> _sendVoteState(String voteType) async {
    if (_voteBarOpen) _toggleVoteBar();
    final ok = await sendVoteState(context, post, voteType);
    // 父级（列表页）不一定订阅了覆盖层，这里自己重建一次把按钮上的
    // 态度回显刷新出来。
    if (ok && mounted) setState(() {});
  }

  // -------------------------------------------------------- 内联评论交互

  /// 展开 / 收起快捷评论条。展开时自动聚焦输入框（下一帧，让键盘顶起时
  /// TextField 的 ensureVisible 把评论条滚进视口）。
  ///
  /// 作者关闭评论的动态（[Post.isCommentClosed]）不开条子：按钮本身已置灰，
  /// 这里是键盘 / 无障碍等旁路进来的兜底，就地回一句提示。
  void _toggleComposer() {
    if (post.isCommentClosed) {
      _toast(commentsClosedNotice);
      return;
    }
    final willOpen = !_composerOpen;
    _anchorHeightChange(!willOpen);
    log.d(LogTag.ui, '${willOpen ? '展开' : '收起'}内联评论条：${post.id}');
    setState(() {
      _composerOpen = willOpen;
      // 与表态条互斥（见 [_voteBarOpen] 的说明）。
      if (willOpen) _voteBarOpen = false;
      if (!willOpen) {
        _composerEmojiOpen = false;
        _composerFocus.unfocus();
      }
    });
    if (willOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _composerFocus.requestFocus();
      });
    }
  }

  /// 展开 / 收起评论条里的表情面板。与键盘互斥：开面板就收键盘。
  void _toggleComposerEmoji() {
    final willOpen = !_composerEmojiOpen;
    // 面板高 235px，属于明显的高度变化，走一次锚定。
    _anchorHeightChange(!willOpen);
    setState(() {
      _composerEmojiOpen = willOpen;
      if (willOpen) {
        _composerFocus.unfocus();
      } else {
        _composerFocus.requestFocus();
      }
    });
  }

  /// 挑选 / 取消一个待发表情（面板点选与角标移除共用）。
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

  /// 发送快捷评论。与详情页 [PostDetailPage] 同一套接口与错误口径：
  /// 表情作为 media 图片项随 body 发送；成功后输入框清空（条子留着
  /// 方便连发），按钮数字用本地增量即时 +1。
  Future<void> _sendInlineComment() async {
    // 界面上的评论入口在作者关闭评论时已经不可点，这里再挡一道：卡片数据
    // 可能是旧缓存（权限是作者后来才关掉的），不挡就会把请求直发服务端，
    // 换来一个语义性 500（见《动态评论权限状态-探查报告.md》第三节）。
    if (post.isCommentClosed) {
      _toast(commentsClosedNotice);
      return;
    }
    final text = _composerInput.text.trim();
    final emojis = List<Emoji>.of(_pendingEmojis);
    if (text.isEmpty && emojis.isEmpty) return;
    final app = AppScope.read(context);
    final token = app.token;
    if (token == null || token.isEmpty) {
      _toast('请先在「我的」页配置登录凭证');
      return;
    }

    setState(() => _sendingComment = true);
    try {
      await SimpleApi().createComment(
        postId: post.id,
        content: text,
        media: emojis,
        token: token,
      );
      log.i(LogTag.ui, '内联评论已发布：${post.id}');
      if (!mounted) return;
      _composerInput.clear();
      _composerFocus.unfocus();
      // 需求（2026-09-22 #9）：发完自动收起评论条 —— 评论已经发出去了，
      // 条子留着只会占着一屏高度。收起属于卡片高度变化，先请列表记锚点。
      _anchorHeightChange(true);
      setState(() {
        _pendingEmojis.clear();
        _composerEmojiOpen = false;
        _composerOpen = false;
        _sentComments++;
        _sendingComment = false;
      });
      _toast('评论已发布');
    } on ApiException catch (e) {
      log.w(LogTag.ui, '内联评论失败：${post.id}｜${e.message}');
      if (!mounted) return;
      if (e.requiresReauth) {
        app.markUnauthorized(e.message);
      } else {
        _toast(e.message);
      }
      setState(() => _sendingComment = false);
    } catch (e) {
      if (!mounted) return;
      _toast('发布失败：$e');
      setState(() => _sendingComment = false);
    }
  }

  void _toast(String msg) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  // ---------------------------------------------------------- 双指捏合折叠

  /// 双指捏合折叠的原始指针跟踪（见 build 里的 Listener 说明）。
  final Map<int, Offset> _pinchPointers = <int, Offset>{};

  /// 两指刚凑齐时的间距。
  double _pinchStartDistance = 0;

  /// 本轮捏合是否已触发（一次捏合只折叠一次）。
  bool _pinchFired = false;

  /// 触发折叠所需的最小收拢距离（逻辑像素）。取值参考触摸 slop 的数倍：
  /// 太小会跟两指乱碰误触，太大则"轻轻一捏"没反应。
  static const double _pinchTriggerDistance = 24;

  void _onPinchPointerDown(PointerDownEvent event) {
    _pinchPointers[event.pointer] = event.position;
    if (_pinchPointers.length == 2) {
      final pts = _pinchPointers.values.toList();
      _pinchStartDistance = (pts[0] - pts[1]).distance;
      _pinchFired = false;
    }
  }

  void _onPinchPointerMove(PointerMoveEvent event) {
    if (!_pinchPointers.containsKey(event.pointer)) return;
    _pinchPointers[event.pointer] = event.position;
    if (_pinchPointers.length != 2 || _pinchFired) return;
    final pts = _pinchPointers.values.toList();
    final distance = (pts[0] - pts[1]).distance;
    if (_pinchStartDistance - distance >= _pinchTriggerDistance) {
      _pinchFired = true;
      log.i(LogTag.ui, '双指捏合折叠：${post.id}（间距 '
          '${_pinchStartDistance.toStringAsFixed(0)} → '
          '${distance.toStringAsFixed(0)}px）');
      _setCollapsed(true);
    }
  }

  void _onPinchPointerUp(PointerEvent event) {
    _pinchPointers.remove(event.pointer);
    // 手指凑齐时会重置基线与触发标记（见 _onPinchPointerDown），这里无须再多做。
  }

  /// 记录一次自身高度，突变（≥240px）时留痕。
  ///
  /// 目的很直接：用户反馈"内容大幅跳跃但日志里什么都没有"。有了这条，
  /// 下一次复现时日志里就能看到是哪一条、跳了多少像素 —— 高度突变要么来自
  /// 用户操作（展开/折叠，已有记录），要么来自布局/数据异常（这条负责兜住）。
  void _measureHeight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ro = context.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) return;
      final h = ro.size.height;
      final prev = _lastHeight;
      _lastHeight = h;
      if (prev == null) return;
      final d = h - prev;
      if (d.abs() >= 240) {
        log.d(
          LogTag.ui,
          '条目高度突变：${post.id} ${prev.toStringAsFixed(0)} → '
          '${h.toStringAsFixed(0)} px（Δ${d > 0 ? '+' : ''}'
          '${d.toStringAsFixed(0)}）',
        );
      }
    });
  }

  /// 上一次测量到的高度。仅用于突变检测。
  double? _lastHeight;

  @override
  Widget build(BuildContext context) {
    _measureHeight();
    // Listener 放在折叠/展开两态的**外层**：折叠发生在手势进行中，子树
    // 会整棵换成摘要行，若 Listener 在里层，已按下的手指抬起事件就收不到，
    // 指针簿记会残留脏数据。
    return Listener(
      // 双指捏合折叠（替代原「双击折叠」）。用 Listener 收原始指针事件：
      // 它不参与手势竞技场，单指的滚动、点击完全不受影响；两指按下并收拢
      // 超过阈值时才触发折叠。因为手指在动，图片九宫格里的单击识别会自然
      // 失败 —— 所以捏合总是先于「点开图片」生效，不会误开查看器。
      // 捏合作用域是整张卡片：卡片之间以列表分割线为界，捏在谁的区域内
      // 折叠的就是谁。
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPinchPointerDown,
      onPointerMove: _onPinchPointerMove,
      onPointerUp: _onPinchPointerUp,
      onPointerCancel: _onPinchPointerUp,
      child: _collapsed ? _collapsedCard() : _expandedCard(),
    );
  }

  /// 折叠态：一行摘要，单击还原。
  Widget _collapsedCard() {
    return InkWell(
      onTap: () => _setCollapsed(false),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    post.hasText
                        ? post.content.replaceAll('\n', ' ')
                        : '[媒体内容]',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.inkTertiary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '已折叠 · 点击展开',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.accent,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 展开态：完整卡片。单击进入详情（不再注册 onDoubleTap，单击无需
  /// 等双击超时）。
  Widget _expandedCard() {
    return InkWell(
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 9),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 正文是否真的溢出 6 行（TextPainter 预判，短文不显示按钮）。
            // 溢出与否决定按钮栏里「展开全文/收起」是否出现。
            final overflows = _textOverflows(constraints.maxWidth);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(),
                if (post.hasText) ...[
                  const SizedBox(height: 9),
                  _content(),
                  // 折叠态的「−请展开阅读−」：正文第六行下方居中一行，
                  // 点击展开（overflows 只在未展开时为 true，见
                  // _textOverflows）。展开后提示行隐藏，收起仍在按钮栏。
                  if (overflows) _expandHint(),
                ],
                if (post.hasCardLinks) ...[
                  const SizedBox(height: 9),
                  for (final url in post.cardLinks) ...[
                    LinkChip(url: url, dense: true),
                    if (url != post.cardLinks.last) const SizedBox(height: 5),
                  ],
                ],
                if (post.media.isNotEmpty) ...[
                  const SizedBox(height: 9),
                  MediaGrid(media: post.media),
                ],
                if (post.isPending) ...[
                  const SizedBox(height: 8),
                  _badge('审核中', color: AppTheme.warning),
                ],
                if (widget.showActions) ...[
                  const SizedBox(height: 7),
                  _actions(showExpand: overflows || _textExpanded),
                ],
                // 表态条：紧贴按钮栏下方原位展开（长按点赞按钮开关）。
                // 与快捷评论条同构、互斥，见 _toggleVoteBar。
                if (_voteBarOpen)
                  VoteStateBar(
                    current: VoteOverlay.instance.postVoteType(post.id),
                    onPick: _sendVoteState,
                  ),
                // 快捷评论条：展开/收起都走锚定（见 _toggleComposer），
                // 放在按钮栏之后，属于卡片自身的高度变化。
                if (_composerOpen) _inlineComposer(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 点作者头像进入 TA 的主页（自己的头像不跳）。
        InkWell(
          onTap: () => _openAuthorProfile(context),
          customBorder: const CircleBorder(),
          child: UserAvatar(user: post.user, size: 38),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    // 昵称统一走 RemarkedText：设过备注就显示「本名（备注名）」。
                    child: RemarkedText(
                      nickname: post.user.nickname,
                      userId: post.user.id,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.inkPrimary,
                      ),
                    ),
                  ),
                  if (post.user.isOfficial) ...[
                    const SizedBox(width: 5),
                    _badge('官方', color: AppTheme.accent, dense: true),
                  ],
                  if (post.user.isNewUser) ...[
                    const SizedBox(width: 5),
                    _badge('新用户', color: AppTheme.success, dense: true),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Text(
                    timeAgo(post.createdAt),
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.inkTertiary,
                    ),
                  ),
                  if (widget.isRead)
                    AnimatedBuilder(
                      animation: AppSettings.instance,
                      builder: (context, _) =>
                          AppSettings.instance.showReadMarkers
                              ? Padding(
                                  padding: const EdgeInsets.only(left: 7),
                                  child: Text(
                                    '已读',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: AppTheme.inkDisabled,
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(),
                    ),
                  if (post.postCollection != null) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: _collectionChip(
                        post.postCollection!.name,
                        onTap: widget.onCollectionTap,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        // 右上角：「在 Simple 中打开」+ 置顶图钉。
        const SizedBox(width: 6),
        _openInSimpleChip(),
        if (post.isPinned)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Icon(Icons.push_pin_outlined,
                size: 15, color: AppTheme.inkTertiary),
          ),
      ],
    );
  }

  /// 点作者头像进入 TA 的主页。自己的头像不跳（"进入他人主页"的需求边界）。
  void _openAuthorProfile(BuildContext context) {
    final uid = post.user.id;
    if (uid.isEmpty) return;
    final me = AppScope.read(context).currentUser?.id;
    if (me != null && me.isNotEmpty && me == uid) return;
    openUserProfile(context, userId: uid, nickname: post.user.nickname);
  }

  /// 「在 Simple 中打开」：打开官方分享页。
  ///
  /// 链接与官方 App"复制链接"生成的完全一致（sharePost?id=<postId>）。
  /// 该链接是一张"唤起 App"降落页：页面会尝试 `simple://sharePost?id=`
  /// 深链。内置浏览器（链接模式）会把这类导航转交系统——装了官方 App
  /// 就直接跳进对应动态（一键直达），没装则留在页面里走官方自己的回落
  /// （官方下载页）。设置里可切回系统浏览器打开，行为一致。
  Widget _openInSimpleChip() {
    return InkWell(
      onTap: () => openInSimple(context, ApiConfig.sharePostUrl(post.id)),
      borderRadius: BorderRadius.circular(5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: AppTheme.surfaceMuted,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.open_in_new_rounded,
                size: 11.5, color: AppTheme.inkTertiary),
            const SizedBox(width: 3),
            Text(
              '在 Simple 中打开',
              style: TextStyle(
                fontSize: 10.5,
                color: AppTheme.inkTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「所属合集」标签。
  ///
  /// 传了 [onTap] 时整块可点，点进去看这个合集的全部动态；
  /// 未传时退化为纯展示（与旧版行为一致）。
  Widget _collectionChip(String name, {VoidCallback? onTap}) {
    final body = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.collections_bookmark_rounded,
            size: 11, color: AppTheme.accent),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              color: AppTheme.accent,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (onTap != null) ...[
          const SizedBox(width: 1),
          Icon(Icons.chevron_right_rounded,
              size: 12, color: AppTheme.accent),
        ],
      ],
    );

    final box = Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: AppTheme.accentMutedBg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: body,
    );

    if (onTap == null) return box;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: box,
    );
  }

  /// 用 TextPainter 预判正文在 [maxWidth] 宽度下是否超过 6 行。
  ///
  /// 已展开时必然"溢出"（按钮栏要显示「收起」），调用方已并入该条件，
  /// 这里只在未展开时计算。
  bool _textOverflows(double maxWidth) {
    if (_textExpanded || !maxWidth.isFinite) return false;
    final tp = TextPainter(
      text: TextSpan(text: post.content, style: _contentStyle),
      maxLines: _maxContentLines,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    return tp.didExceedMaxLines;
  }

  Widget _content() {
    // 正文里的 URL 直接渲染成可点击链接（点击用默认浏览器打开）。
    // 超过 6 行折叠，「展开全文 / 收起」入口在下方按钮栏里（见 _actions）。
    return LinkifiedText(
      text: post.content,
      maxLines: _textExpanded ? null : _maxContentLines,
      style: _contentStyle,
    );
  }

  /// 「−请展开阅读−」提示行：折叠态在正文第六行下方居中显示，点击展开。
  ///
  /// 与按钮栏里的「展开全文」是同一动作的两个入口；展开后提示行隐藏，
  /// 「收起」仍在按钮栏里。
  Widget _expandHint() {
    return Center(
      child: InkWell(
        onTap: _toggleTextExpanded,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Text(
            '−请展开阅读−',
            style: TextStyle(
              fontSize: 12.5,
              color: AppTheme.accent,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  /// 快捷评论条：输入行 + 待发表情条 + 表情面板（都在卡片内部原位展开）。
  ///
  /// **顺序有讲究（2026-09-22 需求）**：输入行必须固定在最上面，待发表情条与
  /// 表情面板一律排在它下方。此前两者在上方，一展开就把输入框整体往下推 ——
  /// 卡片在列表里，被推出去的部分直接超出屏幕，观感就是"点完表情包就看不到
  /// 输入框了"。现在展开面板/选表情都不会移动输入行的位置。
  ///
  /// 键盘与面板互斥：开面板即收键盘（见 [initState] 的焦点监听与
  /// [_toggleComposerEmoji]），点输入框（重新聚焦）会自动收起面板。
  ///
  /// 高度变化由 [_toggleComposer] / [_toggleComposerEmoji] 在变化前走锚定。
  /// EmojiPanel 的表情数据走全局缓存（EmojiCache），多张卡片同时挂面板
  /// 也只拉一次。
  Widget _inlineComposer() {
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _composerInput,
                  focusNode: _composerFocus,
                  // 1~3 行自适应：feed 里条子不宜过高，超长正文回详情页发。
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  minLines: 1,
                  maxLines: 3,
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                    hintText: '说点什么…',
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              IconButton(
                onPressed: _toggleComposerEmoji,
                icon: Icon(
                  _composerEmojiOpen
                      ? Icons.emoji_emotions_rounded
                      : Icons.emoji_emotions_outlined,
                  size: 22,
                ),
                color:
                    _composerEmojiOpen ? AppTheme.accent : AppTheme.inkTertiary,
                tooltip: '表情',
                visualDensity: VisualDensity.compact,
              ),
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 1),
                child: FilledButton(
                  onPressed: _sendingComment ? null : _sendInlineComment,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 38),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: _sendingComment
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('发送', style: TextStyle(fontSize: 13)),
                ),
              ),
            ],
          ),
          if (_pendingEmojis.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: PendingEmojiStrip(
                emojis: _pendingEmojis,
                onRemove: _togglePendingEmoji,
              ),
            ),
          if (_composerEmojiOpen)
            Container(
              height: 235,
              margin: const EdgeInsets.only(top: 7),
              decoration: BoxDecoration(
                color: AppTheme.cardBackground,
                borderRadius: BorderRadius.circular(8),
                border: Border(
                  top: BorderSide(color: AppTheme.divider, width: 0.6),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: EmojiPanel(
                pickedIds: {for (final e in _pendingEmojis) e.id},
                onPick: _togglePendingEmoji,
              ),
            ),
        ],
      ),
    );
  }

  Widget _actions({required bool showExpand}) {
    final voted = post.isVoted;
    final faved = widget.isFavourite ?? post.isFavourited;
    final votes = post.votesCount;
    final comments = post.commentsCount + _sentComments;
    // 我送出的态度（普通赞 / 没送过为 null）。读的是本机覆盖层：服务端
    // 把"我这条是什么状态"藏起来了，详见 `data/vote_states.dart`。
    final voteState =
        VoteStates.byId(VoteOverlay.instance.postVoteType(post.id));
    // 作者关闭评论：评论按钮置灰不可点，按钮栏下方另起一行小字说明
    //（需求 2026-09-23）。
    final commentsClosed = post.isCommentClosed;

    // 互动组：收藏 / 评论 / 点赞。
    //
    // **顺序即需求（2026-09-23）**：从最右侧往左数，第一个是点赞、第二个是
    // 评论、第三个是收藏 —— 因为按钮组默认右置（AppSettings
    // .interactionButtonsOnRight），列表末尾的那个正好贴着右边缘，所以
    // 这里按「左→右 = 收藏、评论、点赞」声明。左置时保持同一相对顺序，
    // 右端依旧是点赞，口径一致。
    //
    // 收藏按钮仅在传入 onFavourite 时出现（合集内容等场景不展示）。
    final interactions = <Widget>[
      if (widget.onFavourite != null) ...[
        _actionItem(
          icon: faved ? Icons.star_rounded : Icons.star_border_rounded,
          label: faved ? '已收藏' : '收藏',
          active: faved,
          activeColor: AppTheme.starColor,
          onTap: () => widget.onFavourite!(!faved),
        ),
        const SizedBox(width: 4),
      ],
      // 评论：不进详情，原位展开/收起快捷评论条（网页微博式）。
      // 作者关闭评论时按钮保持原样文字、只置灰不可点，理由写在下方那行小字里。
      _actionItem(
        icon: Icons.mode_comment_outlined,
        label: comments > 0 ? compactCount(comments) : '评论',
        active: _composerOpen,
        disabled: commentsClosed,
        onTap: commentsClosed ? null : _toggleComposer,
      ),
      const SizedBox(width: 4),
      _actionItem(
        icon: voted ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        // 送过态度就以那个态度的表情 + 短名回显（服务端那句文案太长，
        // 塞不进按钮；完整文案见展开条上的长按提示）。
        emoji: voteState?.emoji,
        label:
            voteState?.short ?? (votes == null ? '赞' : compactCount(votes)),
        active: voted,
        activeColor: AppTheme.likeColor,
        onTap: widget.onVote == null ? null : () => widget.onVote!(!voted),
        // 长按原位展开表态条。没接点赞回调的场景（只读卡片）不长按。
        onLongPress: widget.onVote == null ? null : _toggleVoteBar,
      ),
    ];

    // 操作组：展开全文 / 折叠 / 限制标记。
    final tools = <Widget>[
      if (showExpand) ...[
        _actionItem(
          icon: _textExpanded
              ? Icons.unfold_less_rounded
              : Icons.unfold_more_rounded,
          label: _textExpanded ? '收起' : '展开全文',
          active: false,
          onTap: _toggleTextExpanded,
        ),
        const SizedBox(width: 4),
      ],
      // 折叠整条动态：只留一行摘要，点击还原（双指捏合亦可）。
      _actionItem(
        icon: Icons.unfold_less_rounded,
        label: '折叠',
        active: false,
        onTap: () => _setCollapsed(true),
      ),
    ];

    // 需求（2026-09-22 #12）：互动按钮默认右置（与原来最右侧的"折叠"
    // 交换位置），设置里可切回左置。订阅设置以便切换后立即生效。
    //
    // 需求（2026-09-23）：作者关闭评论时，在按钮栏下方**另起一行**补一句小字
    // 「作者已关闭互动」，并与互动组同侧对齐 —— 置灰的按钮只说明"不能点"，
    // 这行字说明"为什么不能点"。开关切换也在同一个 builder 里重建。
    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (context, _) {
        final onRight = AppSettings.instance.interactionButtonsOnRight;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: onRight
                  ? [...tools, const Spacer(), ...interactions]
                  : [...interactions, const Spacer(), ...tools],
            ),
            if (commentsClosed)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Align(
                  alignment:
                      onRight ? Alignment.centerRight : Alignment.centerLeft,
                  child: Text(
                    commentsClosedNotice,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.inkTertiary,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 按钮栏里的一个按钮。
  ///
  /// [emoji] 传了就替掉图标 —— 点赞按钮用它回显"我送出的态度"
  /// （表情比一个心形更能说明"这条不是普通赞"）。
  Widget _actionItem({
    required IconData icon,
    required String label,
    required bool active,
    Color? activeColor,
    String? emoji,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
    // 置灰态：内容仍然显示，但整枚按钮按下无反应（作者关闭评论的评论按钮）。
    bool disabled = false,
  }) {
    final ac = activeColor ?? AppTheme.accent;
    final color = disabled
        ? AppTheme.inkDisabled
        : (active ? ac : AppTheme.inkTertiary);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (emoji != null)
              Text(emoji, style: const TextStyle(fontSize: 15, height: 1.1))
            else
              Icon(icon, size: 17, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: color,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(String text, {required Color color, bool dense = false}) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 4 : 6,
        vertical: dense ? 0.5 : 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.28), width: 0.6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: dense ? 10 : 11,
          color: color,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
      ),
    );
  }
}
