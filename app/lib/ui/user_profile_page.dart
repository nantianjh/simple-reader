import 'package:flutter/material.dart';

import '../api/api_exception.dart';
import '../api/models.dart';
import '../api/simple_api.dart';
import '../data/user_remarks.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../state/load_phase.dart';
import '../state/user_profile_state.dart';
import '../util/app_log.dart';
import 'actions.dart';
import 'collection_detail_page.dart';
import 'post_detail_page.dart';
import 'theme.dart';
import 'widgets/brightness_aware.dart';
import 'widgets/paged_post_list.dart';
import 'widgets/post_card.dart';
import 'widgets/read_tracker.dart';
import 'widgets/remark_name.dart';
import 'widgets/state_views.dart';
import 'widgets/user_avatar.dart';

/// 进入他人主页的统一入口（动态卡片头像、详情页作者与评论者头像共用）。
///
/// 只对**他人**开放：调用方（PostCard 内部）会用当前登录用户 id 拦下自己。
Future<void> openUserProfile(
  BuildContext context, {
  required String userId,
  String nickname = '',
}) async {
  if (userId.isEmpty) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => UserProfilePage(userId: userId, nickname: nickname),
    ),
  );
}

/// 他人主页：资料头部 + 动态流。
///
/// 数据口径（《四需求可行性-探查报告.md》第二节实测）：
/// * 头部 `GET api/v2/users/{id}` —— 对外字段 + 关系态一次拿全；
///   **粉丝/关注列表做不了**（`follows/followers` 与 `user_badges` 的
///   `user_id` 会被服务端静默忽略、永远返回"我的"），所以这里没有
///   粉丝列表，也不放"查看徽章"之类的入口。
/// * 动态流 `GET api/v2/posts/profile?user_id=`（与合集内容同端点，
///   不带合集参数），复用分页式瀑布流与续读机制。
///
/// 隐私口径：服务端对 `is_hide_gender_age=true` 的用户仍会下发
/// `birthday`，本页**不展示生日**，避免把服务端的隐私漏洞显式呈现。
class UserProfilePage extends StatefulWidget {
  const UserProfilePage({
    super.key,
    required this.userId,
    this.nickname = '',
  });

  final String userId;

  /// 调用方已知的昵称（头部接口返回前先显示它）。
  final String nickname;

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  final ScrollController _scroll = ScrollController();
  final SimpleApi _api = SimpleApi();
  late final ItemVisibilityTracker _tracker;
  late UserProfilePostsController _posts;

  UserProfile? _profile;
  bool _profileLoading = false;
  String? _profileError;

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    _tracker = ItemVisibilityTracker(_scroll);
    _posts = UserProfilePostsController(
      tokenProvider: () => app.token,
      userId: widget.userId,
    )..onAuthFailure = (msg) {
        if (mounted) app.markUnauthorized(msg);
      };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _posts.ensureLoaded();
    });
    _loadProfile();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _posts.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final app = AppScope.read(context);
    final token = app.token;
    if (token == null || token.isEmpty || widget.userId.isEmpty) {
      setState(() => _profileError = '未配置 token，无法获取资料');
      return;
    }
    setState(() {
      _profileLoading = true;
      _profileError = null;
    });
    try {
      final profile = await _api.fetchUserProfile(token: token, userId: widget.userId);
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _profileLoading = false;
        if (profile == null) _profileError = '没有取到该用户的资料';
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.requiresReauth) app.markUnauthorized(e.message);
      setState(() {
        _profileError = e.message;
        _profileLoading = false;
      });
    } catch (e) {
      log.w(LogTag.net, '他人主页资料加载失败：$e');
      if (!mounted) return;
      setState(() {
        _profileError = '资料加载失败：$e';
        _profileLoading = false;
      });
    }
  }

  // ---------------------------------------------------------------- 关注

  /// 关注态的本地覆盖（乐观更新用）。null = 用服务端下发的值。
  bool? _followOverride;

  /// 关注请求进行中（按钮转圈 + 防重复提交）。
  bool _followBusy = false;

  bool get _isFollowing => _followOverride ?? (_profile?.isFollowing ?? false);

  /// 当前登录用户是否就是这个主页的主人。
  ///
  /// ⚠️ **自己的主页必须隐藏关注入口**：服务端不拒绝自关注（对自己的 id 也
  /// 返回 201，见探查报告第 1 节），拦不了就只能客户端拦。
  bool _isSelf(AppState app) {
    final myId = app.currentUser?.id ?? app.jwt?.userId ?? '';
    return myId.isNotEmpty && myId == widget.userId;
  }

  /// 关注 / 取关。乐观更新、失败回滚（与点赞同一口径）。
  Future<void> _toggleFollow() async {
    final app = AppScope.read(context);
    final token = app.token;
    if (token == null || token.isEmpty) {
      _toast('请先在「我的」页配置登录凭证');
      return;
    }
    if (_followBusy) return;

    final target = !_isFollowing;
    setState(() {
      _followBusy = true;
      _followOverride = target; // 乐观更新
    });
    try {
      await _api.follow(userId: widget.userId, on: target, token: token);
      log.i(LogTag.ui, '${target ? '关注' : '取消关注'}成功：${widget.userId}');
      if (!mounted) return;
      setState(() => _followBusy = false);
      _toast(target ? '已关注' : '已取消关注');
    } on ApiException catch (e) {
      log.w(LogTag.ui,
          '${target ? '关注' : '取消关注'}失败：${widget.userId}｜${e.message}');
      if (!mounted) return;
      setState(() {
        _followOverride = null; // 回滚到服务端值
        _followBusy = false;
      });
      if (e.requiresReauth) {
        app.markUnauthorized(e.message);
      } else {
        _toast(e.message);
      }
    } catch (e, st) {
      log.exception(LogTag.ui, '关注异常：${widget.userId}', e, st);
      if (!mounted) return;
      setState(() {
        _followOverride = null;
        _followBusy = false;
      });
      _toast('操作失败：$e');
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

  // ---------------------------------------------------------------- 备注

  /// 备注入口（2026-09-23 需求 3）：给 TA 起个本地叫法。
  ///
  /// 备注只存本机（[UserRemarksStore]），设好之后应用里所有显示昵称的地方
  /// 都是「本名（备注名）」；导出备份的类别里也带它。
  Future<void> _editRemark() async {
    final nickname = _profile?.user.nickname ?? widget.nickname;
    final current = UserRemarksStore.instance.remarkOf(widget.userId) ?? '';
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _RemarkDialog(nickname: nickname, current: current),
    );
    if (result == null || !mounted) return; // 取消：保持原样
    await UserRemarksStore.instance.setRemark(
      userId: widget.userId,
      nickname: nickname,
      remark: result,
    );
    if (!mounted) return;
    setState(() {}); // 顶部标题/头部的展示名跟着变
    _toast(result.trim().isEmpty ? '已清除备注' : '备注已保存');
  }

  @override
  Widget build(BuildContext context) {
    // 包一层亮度依赖：本页配色全是静态语义色，不重建就会停在旧主题。
    return BrightnessAware(builder: (context, _) => _contents(context));
  }

  Widget _contents(BuildContext context) {
    final app = AppScope.of(context);
    final name = _profile?.user.nickname ?? widget.nickname;

    return Scaffold(
      backgroundColor: AppTheme.pageBackground,
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: UserRemarksStore.instance,
          builder: (context, _) => Text(
            name.isEmpty
                ? '个人主页'
                : UserRemarksStore.instance.display(name, widget.userId),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        actions: [
          // 备注入口：只在**他人**主页出现（自己的主页没有备注的意义）。
          // 已具备备注时图标点亮，一眼能看出这个人已经改过名字。
          if (!_isSelf(app))
            ListenableBuilder(
              listenable: UserRemarksStore.instance,
              builder: (context, _) {
                final has = UserRemarksStore.instance.has(widget.userId);
                return IconButton(
                  tooltip: has ? '修改备注' : '备注',
                  onPressed: _editRemark,
                  color: has ? AppTheme.accent : null,
                  icon: const Icon(Icons.edit_note_rounded, size: 22),
                );
              },
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _header(app),
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

  // ---------------------------------------------------------------- 头部

  Widget _header(AppState app) {
    final p = _profile;
    final user = p?.user;
    final name = user?.nickname ?? widget.nickname;
    // 关注入口：资料到手、且**不是自己的主页**时才出现（服务端拦不住自关注）。
    final showFollow = p != null && !_isSelf(app);

    return Container(
      width: double.infinity,
      color: AppTheme.cardBackground,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              UserAvatar(user: user ?? SimpleUser.empty, size: 62),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: name.isEmpty
                              ? Text(
                                  '…',
                                  style: TextStyle(
                                    fontSize: 16.5,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.inkPrimary,
                                  ),
                                )
                              : RemarkedText(
                                  // 设过备注就显示「本名（备注名）」。
                                  nickname: name,
                                  userId: widget.userId,
                                  style: TextStyle(
                                    fontSize: 16.5,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.inkPrimary,
                                  ),
                                ),
                        ),
                        if (user?.isOfficial ?? false) ...[
                          const SizedBox(width: 5),
                          Icon(Icons.verified_rounded,
                              size: 15, color: AppTheme.accent),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _metaLine(p),
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.inkTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              if (showFollow) ...[
                const SizedBox(width: 10),
                _followButton(),
              ],
            ],
          ),
          if (_profileLoading) ...[
            const SizedBox(height: 10),
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            ),
          ],
          if (p != null && p.bio.isNotEmpty) ...[
            const SizedBox(height: 9),
            Text(
              p.bio,
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.inkSecondary,
                height: 1.55,
              ),
            ),
          ],
          if (p != null && _relationChips(p).isNotEmpty) ...[
            const SizedBox(height: 9),
            Wrap(spacing: 6, runSpacing: 6, children: _relationChips(p)),
          ],
          if (_profileError != null) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _loadProfile,
              child: Text(
                '$_profileError（点击重试）',
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.warning,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 概要行：等级 / 徽章数 / 加入时间。拿不到的项静默跳过。
  String _metaLine(UserProfile? p) {
    if (p == null) return '';
    final parts = <String>[
      if (p.level > 0) 'Lv.${p.level}',
      if (p.badgesCount > 0) '${p.badgesCount} 枚徽章',
      if (p.createdAt != null) '${p.createdAt!.year} 年加入',
    ];
    return parts.join(' · ');
  }

  /// 关注 / 已关注按钮。
  ///
  /// 未关注用实心按钮（引导动作），已关注用描边按钮（弱化，避免误触取消）。
  /// 请求中按钮转圈并禁用，防重复提交。
  Widget _followButton() {
    final following = _isFollowing;
    if (!following) {
      return FilledButton(
        onPressed: _followBusy ? null : _toggleFollow,
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: _followBusy
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : const Text('关注', style: TextStyle(fontSize: 13)),
      );
    }
    return OutlinedButton(
      onPressed: _followBusy ? null : _toggleFollow,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: AppTheme.inkSecondary,
        side: BorderSide(color: AppTheme.divider, width: 0.8),
      ),
      child: _followBusy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('已关注', style: TextStyle(fontSize: 13)),
    );
  }

  /// 关系态标签。布尔值来自 users/{id}，无需额外请求。
  List<Widget> _relationChips(UserProfile p) {
    final chips = <Widget>[];
    void add(String text, Color color) {
      chips.add(Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 0.6),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 10.5,
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ));
    }

    if (p.isBlocked) add('已拉黑', AppTheme.inkTertiary);
    if (p.isMuted) add('已静音', AppTheme.inkTertiary);
    // 「已关注」不再单独做标签：它由关注按钮表达（2026-09-22 需求），
    // 这里只留"关系性质"的标签，避免同一件事说两遍。
    if (p.isFriend) {
      add('互相关注', AppTheme.accent);
    } else if (p.isFollower) {
      add('关注了你', AppTheme.success);
    }
    return chips;
  }

  // ---------------------------------------------------------------- 列表

  Widget _body() {
    if (_posts.phase == LoadPhase.loadingFirst && _posts.posts.isEmpty) {
      return const LoadingView(message: '正在拉取动态…');
    }
    if (_posts.phase == LoadPhase.error && _posts.posts.isEmpty) {
      return ErrorView(
        message: _posts.error ?? '加载失败',
        onRetry: _posts.retry,
      );
    }
    if (_posts.isEmptyResult) {
      return const EmptyView(
        icon: Icons.inbox_outlined,
        title: 'TA 还没有公开的动态',
      );
    }

    return PagedPostList(
      controller: _posts,
      scrollController: _scroll,
      tracker: _tracker,
      // 缓存状态条：顶部明确当前这屏动态是本地缓存还是刚抓的
      //（与搜索页、收藏页同一口径同一组件）。个人主页同样会命中缓存
      //（翻过的人主页再进来就是 preferCache 命中），此前这里没有任何提示。
      header: _posts.fromCache && _posts.cachedAt != null
          ? CacheHintBar(cachedAt: _posts.cachedAt!)
          : null,
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
        // 他人主页里点合集标签 → 进入该合集（作者+合集双参数，同一链路）。
        onCollectionTap: () => openCollectionOfPost(context, post),
      ),
    );
  }
}

/// 「备注」对话框：设置 / 修改 / 清除某个用户的备注名。
///
/// 做成 StatefulWidget 是刻意的（与 `_JumpPageDialog` 同一理由）：
/// TextEditingController 由它自己持有并在 `dispose()` 里释放 —— 对话框
/// 确认/取消后还有一段退出动画，动画期间输入框仍挂载，若在外层 await
/// 返回后立刻 dispose，InputDecorator 重建时会撞上 "used after being
/// disposed"。
///
/// 返回值：新备注名（空串 = 清除）；返回 null = 取消（不改变现状）。
class _RemarkDialog extends StatefulWidget {
  const _RemarkDialog({required this.nickname, required this.current});

  /// 对方当前的本名（用于对话框里的效果预览）。
  final String nickname;

  /// 已设备注名。空串 = 尚未设备注。
  final String current;

  @override
  State<_RemarkDialog> createState() => _RemarkDialogState();
}

class _RemarkDialogState extends State<_RemarkDialog> {
  late final TextEditingController _input =
      TextEditingController(text: widget.current);

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('备注', style: TextStyle(fontSize: 17)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '给 TA 起个本地叫法：只存在这台手机上，不会同步给对方，'
              '也不影响任何互动。设置后应用里都显示「本名（备注名）」，'
              '导出备份时会一并带出。',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: AppTheme.inkTertiary,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _input,
              autofocus: true,
              maxLength: 20,
              textInputAction: TextInputAction.done,
              onSubmitted: (v) => Navigator.of(context).pop(v),
              decoration: const InputDecoration(
                labelText: '备注名',
                hintText: '例如：同事老王',
              ),
            ),
            // 效果预览：边输边看到"全应用会显示成什么样"。
            ListenableBuilder(
              listenable: _input,
              builder: (context, _) => Text(
                '显示为：${UserRemark.compose(widget.nickname, _input.text)}',
                style: TextStyle(
                  fontSize: 12.5,
                  color: AppTheme.inkSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.current.isNotEmpty)
          TextButton(
            onPressed: () => Navigator.of(context).pop(''),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: const Text('清除备注'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_input.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
