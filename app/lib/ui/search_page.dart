import 'package:flutter/material.dart';

import '../api/simple_api.dart';
import '../data/reading_positions.dart';
import '../data/search_history.dart';
import '../data/settings.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../state/load_phase.dart';
import '../state/search_state.dart';
import '../util/app_log.dart';
import '../util/format.dart';
import 'actions.dart';
import 'collection_detail_page.dart';
import 'post_detail_page.dart';
import 'theme.dart';
import 'widgets/brightness_aware.dart';
import 'widgets/paged_post_list.dart';
import 'widgets/post_card.dart';
import 'widgets/read_tracker.dart';
import 'widgets/state_views.dart';

/// 搜索页。
///
/// 走契约第三节的 v3 搜索接口；参数名、游标语义、每页条数
/// 均按契约硬约束实现，不做本地变通。结果按 10 条一页组织，
/// 翻页由 [PagedPostList] 负责（页面顶部/底部触边双向补页）。
///
/// 三项与阅读体验相关的行为：
/// * 搜索框保留历史记录（MRU）；没有内容可展示时，历史关键词以
///   多排独立按钮的形式铺在结果区，点一下即重新检索；
/// * 命中已存档的续读点时会询问是否续读，复选框默认勾选续读；
/// * 「续读」走纯本地缓存，跳到存档页号后仍可继续向上/向下翻页。
///
/// v1.7.2 新增屏蔽关键词：正文完整包含任一关键词的动态不出现在
/// 结果里，过滤条数在状态条上提示（见 [_filteredBanner]）。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

/// 续读询问的结果。
class _ResumeChoice {
  const _ResumeChoice({required this.resume, required this.neverAsk});

  final bool resume;
  final bool neverAsk;
}

class _SearchPageState extends State<SearchPage>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  late final SearchPageController _search;
  late final ItemVisibilityTracker _tracker;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    _tracker = ItemVisibilityTracker(_scroll);
    _search = SearchPageController(
      api: SimpleApi(),
      tokenProvider: () => app.token,
    )..onAuthFailure = (msg) {
        if (mounted) app.markUnauthorized(msg);
      };
  }

  @override
  void dispose() {
    _scroll.dispose();
    _controller.dispose();
    _search.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 提交

  Future<void> _submit() async {
    final q = _controller.text.trim();
    if (q.isEmpty) {
      _toast('请输入搜索关键词');
      return;
    }

    // 强制联网只看「是否同一个词」，不看输入路径：
    // - 同词再次提交（点搜索按钮，或再点同一个历史词）=「要新内容」的
    //   显式请求：不再询问是否续读（那会把用户又带回同一份缓存），直接
    //   联网重抓；被替换掉的缓存内容会由「上次浏览到这儿」分界线标注，
    //   随时可以往下滑回去。
    // - 换词（点历史词、输入新词）永不强制联网：有存档点按下面的续读
    //   询问/默认续读走，无存档点走普通 preferCache——有缓存命中缓存，
    //   没缓存才联网。切换搜索词不应触发联网重抓。
    final sameTerm = _search.hasSearched && _search.keyword == q;

    FocusScope.of(context).unfocus();
    _historyMode = false;

    ReadingPosition? resumeAt;
    if (!sameTerm) {
      final saved = _search.positionFor(q);
      resumeAt = saved;
      final resumable = saved != null && (saved.page > 0 || saved.index > 0);

      if (resumable && AppSettings.instance.askResumeOnSearch) {
        final choice = await _askResume(q, saved);
        if (choice == null) return; // 用户取消，保持当前结果不动
        if (!choice.resume) resumeAt = null;
        if (choice.neverAsk) {
          await AppSettings.instance.setAskResumeOnSearch(false);
        }
      } else if (resumable && !AppSettings.instance.askResumeOnSearch) {
        // 用户关掉了询问：默认按续读处理。
        resumeAt = saved;
      } else {
        resumeAt = null;
      }
    }

    await _search.search(q, resumeAt: resumeAt, forceNetwork: sameTerm);

    if (resumeAt != null && mounted) {
      await _jumpToReadPosition();
    }
    if (mounted) setState(() {});
  }

  /// 续读询问对话框。复选框默认勾选「续读到上次位置」。
  Future<_ResumeChoice?> _askResume(String keyword, ReadingPosition pos) {
    var resume = true;
    var never = false;

    return showDialog<_ResumeChoice>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('续读上次位置', style: TextStyle(fontSize: 17)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '「$keyword」上次停在第 ${pos.page + 1} 页'
                '（第 ${pos.index + 1} 条），${timeAgo(pos.updatedAt)}。',
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.6,
                  color: AppTheme.inkSecondary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '续读直接回到上次停留的位置（第 ${pos.page + 1} 页），'
                '之后仍可继续向上、向下翻页；'
                '内容全部来自本地缓存，不会发起新的抓取请求。',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: AppTheme.inkTertiary,
                ),
              ),
              const SizedBox(height: 2),
              CheckboxListTile(
                value: resume,
                onChanged: (v) => setLocal(() => resume = v ?? false),
                title: const Text('回到上次停留的位置',
                    style: TextStyle(fontSize: 14)),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                visualDensity: VisualDensity.compact,
              ),
              CheckboxListTile(
                value: never,
                onChanged: (v) => setLocal(() => never = v ?? false),
                title: const Text('以后不再询问',
                    style: TextStyle(fontSize: 14)),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(
                _ResumeChoice(resume: resume, neverAsk: never),
              ),
              child: const Text('开始'),
            ),
          ],
        ),
      ),
    );
  }

  /// 跳到存档页并滚到存档条目。
  Future<void> _jumpToReadPosition() async {
    final pos = _search.savedPosition;
    if (pos == null) return;
    log.i(
      LogTag.read,
      '搜索续读 → 第 ${pos.page + 1} 页（条目 ${pos.postId}，'
      '停留于 ${timeAgo(pos.updatedAt)}）',
    );

    if (!_search.hasPage(pos.page)) {
      await _search.jumpToPage(pos.page);
    }
    if (!mounted) return;

    final index = _search.indexOfPostId(pos.postId);
    if (index < 0) {
      // 内容已变动、原条目不在当前页：退回页首。
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

  // ------------------------------------------------------------ 搜索历史

  /// 是否正在看「历史搜索词列表」。
  ///
  /// 与 [SearchPageController.hasSearched] 无关：结果还在（点一下就能回去），
  /// 只是把结果区临时让给历史词列表。搜索框右侧的按钮切换这个状态。
  bool _historyMode = false;

  void _openHistory() {
    FocusScope.of(context).unfocus();
    log.d(LogTag.ui, '切到搜索历史列表（上次检索：${_search.keyword}）');
    setState(() => _historyMode = true);
  }

  void _backToResults() {
    setState(() => _historyMode = false);
  }

  /// 历史区的「删除模式」开关。
  ///
  /// 默认关闭：正常模式下每条历史关键词只是一个可点击的检索按钮，
  /// 不带删除图标（避免误删，也让历史墙更干净）。
  /// 打开后每条才出现删除按钮，顶部按钮变成「完成」。
  bool _historyDeleteMode = false;

  Future<void> _pickHistory(String keyword) async {
    if (_historyDeleteMode) return; // 删除模式下点词条不触发检索
    _controller.text = keyword;
    _controller.selection = TextSelection.collapsed(offset: keyword.length);
    await _submit();
  }

  Future<void> _removeHistory(String keyword) async {
    await SearchHistory.instance.remove(keyword);
    log.i(LogTag.app, '删除一条搜索历史：「$keyword」');
    if (!mounted) return;
    setState(() {});
    if (SearchHistory.instance.isEmpty) {
      // 删到最后一条时自动退出删除模式，否则顶部只剩一个空按钮。
      setState(() => _historyDeleteMode = false);
      _toast('搜索历史已清空');
    }
  }

  void _toggleHistoryDeleteMode() {
    setState(() => _historyDeleteMode = !_historyDeleteMode);
  }

  Future<void> _clearHistory() async {
    final n = SearchHistory.instance.length;
    await SearchHistory.instance.clear();
    log.i(LogTag.app, '清空搜索历史：$n 条');
    if (!mounted) return;
    setState(() => _historyDeleteMode = false);
    _toast('已清空搜索历史');
  }

  void _toast(String msg) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2, milliseconds: 200),
        ),
      );
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 包一层亮度依赖：本页配色全是静态语义色（读它不注册任何依赖），
    // 系统在「跟随系统」模式下切换明暗时必须让本页重建，否则搜索框、
    // 空态、历史墙上已经渲染出来的颜色会停在旧主题。
    return BrightnessAware(builder: (context, _) => _contents(context));
  }

  Widget _contents(BuildContext context) {
    final app = AppScope.of(context);

    return Scaffold(
      backgroundColor: AppTheme.pageBackground,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _searchBar(),
            if (app.status == AuthStatus.invalid && app.errorMessage != null)
              AuthBanner(message: app.errorMessage!),
            Expanded(
              child: AnimatedBuilder(
                animation: _search,
                builder: (context, _) => _results(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchBar() {
    return Container(
      color: AppTheme.cardBackground,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submit(),
              style: const TextStyle(fontSize: 14.5),
              decoration: InputDecoration(
                hintText: '搜索内容…',
                prefixIcon: Icon(Icons.search_rounded,
                    size: 19, color: AppTheme.inkTertiary),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 38, minHeight: 38),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: Icon(Icons.cancel,
                            size: 16, color: AppTheme.inkTertiary),
                        onPressed: () {
                          _controller.clear();
                          setState(() {});
                        },
                        splashRadius: 16,
                      ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 回历史搜索词列表：搜索框右侧的常驻入口。
          // 结果页看腻了不必清空关键词，点它就是历史词墙；历史墙里再点一条
          // 直接换关键词重搜（见 _pickHistory）。
          IconButton(
            tooltip: _historyMode ? '返回上次检索结果' : '搜索历史',
            onPressed: _historyMode ? _backToResults : _openHistory,
            icon: Icon(
              _historyMode
                  ? Icons.manage_search_rounded
                  : Icons.history_rounded,
              size: 20,
            ),
            color: _historyMode ? AppTheme.accent : AppTheme.inkSecondary,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
          ),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: _submit,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 42),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            child: const Text('搜索'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 结果

  Widget _results() {
    // 还没有内容可展示，或用户点了「搜索历史」：铺开历史关键词按钮墙。
    if (_historyMode || !_search.hasSearched) return _historyWall();

    if (_search.phase == LoadPhase.loadingFirst && _search.posts.isEmpty) {
      return const LoadingView(message: '正在检索…');
    }
    if (_search.phase == LoadPhase.error && _search.posts.isEmpty) {
      return ErrorView(
        message: _search.error ?? '加载失败',
        onRetry: _search.retry,
      );
    }
    if (_search.isEmptyResult) return _noResult();

    return PagedPostList(
      controller: _search,
      scrollController: _scroll,
      tracker: _tracker,
      header: Column(
        children: [
          _statusBanner(),
          _filteredBanner(),
        ],
      ),
      itemBuilder: (context, post, index) => PostCard(
        post: post,
        isRead: _search.isReadAt(index),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => PostDetailPage(post: post)),
        ),
        onCollectionTap: () => openCollectionOfPost(context, post),
        onVote: (target) async {
          final ok = await toggleVote(context, post);
          if (ok && mounted) setState(() {});
        },
        onFavourite: (target) async {
          final ok = await toggleFavourite(context, post);
          if (ok && mounted) setState(() {});
        },
      ),
    );
  }

  /// 结果区的状态条：缓存来源 / 续读模式 / 一次性提示。
  Widget _statusBanner() {
    final notice = _search.notice;
    final fromCache = _search.fromCache && _search.cachedAt != null;

    if (notice != null) {
      return _banner(
        icon: Icons.info_outline_rounded,
        color: AppTheme.warning,
        background: AppTheme.warningBackground,
        text: notice,
        action: TextButton(
          onPressed: _search.clearNotice,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 28),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('知道了', style: TextStyle(fontSize: 12)),
        ),
      );
    }

    if (!fromCache) return const SizedBox.shrink();

    final text = _search.offlineReading
        ? '续读模式：内容全部来自本地缓存（抓取于 ${timeAgo(_search.cachedAt)}），'
            '未发起新的抓取'
        : '内容来自本地缓存（抓取于 ${timeAgo(_search.cachedAt)}）';

    return _banner(
      icon: Icons.offline_bolt_outlined,
      color: AppTheme.accent,
      background: AppTheme.infoBackground,
      text: text,
    );
  }

  /// 屏蔽关键词过滤提示：本次检索累计隐藏了多少条。
  Widget _filteredBanner() {
    final n = _search.filteredCount;
    if (n == 0) return const SizedBox.shrink();
    return _banner(
      icon: Icons.filter_alt_off_outlined,
      color: AppTheme.inkSecondary,
      background: AppTheme.surfaceMuted,
      text: '已按屏蔽关键词隐藏 $n 条动态（在「我的 → 搜索」中管理）',
    );
  }

  Widget _banner({
    required IconData icon,
    required Color color,
    required Color background,
    required String text,
    Widget? action,
  }) {
    return Container(
      color: background,
      padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
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
          if (action != null) action,
        ],
      ),
    );
  }

  /// 命中为空：给一句说明，然后把历史关键词铺出来备用。
  Widget _noResult() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 16),
          child: Column(
            children: [
              Icon(Icons.search_off_rounded,
                  size: 40, color: AppTheme.inkDisabled),
              const SizedBox(height: 12),
              Text(
                '没有匹配「${_search.keyword}」的内容',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.inkSecondary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '换个关键词试试，或从下面的历史关键词里挑一个。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: AppTheme.inkTertiary,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 0.6),
        Expanded(child: _historyWall()),
      ],
    );
  }

  // ------------------------------------------------------------ 历史按钮墙

  /// 历史关键词：多排、每个都是独立按钮。
  ///
  /// 搜索页「无内容可显示」时（尚未检索 / 检索无结果）用它填充结果区，
  /// 替代原来那套「聚焦才弹出的单列历史列表」。
  ///
  /// 顶部右侧是「删除 / 完成」切换：只有进入删除模式后，每条关键词才带上
  /// 删除按钮（见 [_historyChip]）。
  Widget _historyWall() {
    final items = SearchHistory.instance.items;

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
      children: [
        // 从结果页切过来的：给一条明确的回头路，别让上次的结果白跑一趟。
        if (_search.hasSearched && _search.posts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: OutlinedButton.icon(
              onPressed: _backToResults,
              icon: const Icon(Icons.arrow_back_rounded, size: 16),
              label: Text(
                '返回「${_search.keyword}」的检索结果',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
        Row(
          children: [
            Icon(Icons.history_rounded,
                size: 15, color: AppTheme.inkTertiary),
            const SizedBox(width: 6),
            Text(
              '搜索历史',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.inkSecondary,
              ),
            ),
            const Spacer(),
            if (items.isNotEmpty)
              TextButton(
                onPressed: _toggleHistoryDeleteMode,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor:
                      _historyDeleteMode ? AppTheme.danger : AppTheme.accent,
                ),
                child: Text(
                  _historyDeleteMode ? '完成' : '删除',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            if (items.isNotEmpty)
              TextButton(
                onPressed: _clearHistory,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: AppTheme.inkTertiary,
                ),
                child: const Text('清空', style: TextStyle(fontSize: 12.5)),
              ),
          ],
        ),
        if (_historyDeleteMode && items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 2),
            child: Text(
              '点击每条右侧的 ✕ 删除该关键词；点「完成」退出删除模式。',
              style: TextStyle(
                fontSize: 11.5,
                color: AppTheme.inkTertiary,
                height: 1.5,
              ),
            ),
          ),
        const SizedBox(height: 8),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 26),
            child: Center(
              child: Text(
                '还没有搜索记录\n输入关键词开始检索',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: AppTheme.inkTertiary,
                  height: 1.8,
                ),
              ),
            ),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final k in items) _historyChip(k),
            ],
          ),
      ],
    );
  }

  Widget _historyChip(String keyword) {
    final deleting = _historyDeleteMode;
    return InkWell(
      onTap: () => _pickHistory(keyword),
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: EdgeInsets.fromLTRB(12, 7, deleting ? 6 : 12, 7),
        decoration: BoxDecoration(
          color: AppTheme.cardBackground,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: deleting ? AppTheme.dangerBorder : AppTheme.divider,
            width: 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                keyword,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  color: AppTheme.inkPrimary,
                ),
              ),
            ),
            // 删除按钮只在删除模式下出现。
            if (deleting) ...[
              const SizedBox(width: 2),
              InkWell(
                onTap: () => _removeHistory(keyword),
                borderRadius: BorderRadius.circular(9),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(Icons.close_rounded,
                      size: 13, color: AppTheme.danger),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
