import 'package:flutter/material.dart';

import '../data/favourite_collections.dart';
import '../data/settings.dart';
import '../state/app_scope.dart';
import '../state/collections_state.dart';
import '../state/load_phase.dart';
import '../util/app_log.dart';
import 'actions.dart';
import 'post_detail_page.dart';
import 'theme.dart';
import 'widgets/paged_post_list.dart';
import 'widgets/post_card.dart';
import 'widgets/read_tracker.dart';
import 'widgets/state_views.dart';

/// 收藏页的「合集」视图：顶部合集按钮墙 + 下方所选合集的内容。
///
/// 交互口径：
/// * **不自动解析** —— 进入本视图不自动抓收藏动态解析合集，收录只由
///   AppBar 的**唯一一个同步按钮**手动触发。该按钮是一条命令两种口径：
///   本机目录还是空的（尚未初始化）→ 翻遍全部收藏动态（完整同步）；
///   已有数据 → 只同步最新一页 10 条。按钮本身不再弹任何说明或确认框，
///   原理说明集中在首次进入本视图时的一次性说明页（见 [_maybeShowIntro]）。
/// * **不自动选中** —— 不点击任何合集前，下方不显示合集内内容；
/// * 合集可**订阅**（长按按钮墙条目或选中后的铃铛按钮）：订阅后冷启动
///   会串行扫描合集内有无新动态，有则在合集名称右侧显示红点。
///
/// [CollectionsController] 只负责取数与解析；本条目的增删（本地墓碑）与
/// 订阅红点都由 [FavouriteCollectionsStore] 承担。
///
/// 布局分两层：
/// * **顶部**：工具行（标题 / 说明 / 管理）+ 同步状态条 + 全部合集的缩小按钮
///   （Wrap 墙），点选切换下方内容；往下浏览内容时自动收起、回到内容顶部再
///   展开（2026-09-22 #5），管理模式或尚未选中合集时不收起；
/// * **内容（滚动）**：选中合集的动态流（复用 [PagedPostList]），
///   未选中时给提示；选中合集的信息条上带订阅与「移除」入口。
///
/// 列表级管理：顶部工具行的「管理」进入多选，可全选/批量移除本机目录里的
/// 合集（2026-09-22 #6 —— 该能力随 v1.7.1 删掉 `collections_page.dart` 一并
/// 丢失，这里按用户要求补回本视图，不恢复独立页面）。
class FavoritesCollectionsView extends StatefulWidget {
  const FavoritesCollectionsView({
    super.key,
    required this.collections,
    required this.ownerUserId,
  });

  /// 由收藏页持有并传入的合集目录控制器（同步/移除/恢复都在它身上）。
  final CollectionsController collections;

  /// 当前登录用户 id（判断合集是否自己的 → posts/mine 或 posts/profile）。
  final String ownerUserId;

  @override
  State<FavoritesCollectionsView> createState() =>
      FavoritesCollectionsViewState();
}

class FavoritesCollectionsViewState extends State<FavoritesCollectionsView> {
  final ScrollController _scroll = ScrollController();
  late final ItemVisibilityTracker _tracker;

  /// 当前选中的合集 id。null = 尚未选择。
  String? _selectedId;

  CollectionPostsController? _posts;

  /// 顶部合集区是否展开。
  ///
  /// 需求（2026-09-22 #5）：往下浏览合集内容时自动收起顶部合集列表，回到内容
  /// 顶部再往下滑时重新展开 —— 与微信列表页下拉露出搜索/小程序入口同一手感。
  /// 收起后内容区视野变大，且**不改动内容坐标系**：列表视口只是变高，
  /// 条目在视口内的位置不变，所以补页的锚点实测（`viewportTopOfKey` 是
  /// 相对列表自身的偏移）不受影响。
  bool _topExpanded = true;

  /// 上一次内容滚动偏移，用于判定滚动方向。
  double _lastContentOffset = 0;

  /// 同方向上的累计位移（用来判定"用户正在往哪边滚"）。
  ///
  /// ⚠️ 必须累计，不能拿单次 delta 直接比阈值：滚动回调是**每个指针事件/
  /// 每帧**来的，慢速滑动时单次位移只有几像素，永远达不到阈值 —— 用户实测
  /// 就是"必须快速向上甩动才会收起，正常速度滑动几乎不响应"。反向时归零。
  double _scrollTravel = 0;

  /// 触发收放所需的**同向累计**位移（逻辑像素）。
  ///
  /// 取 1/3 个卡片高度左右：既能让慢速滑动在几十像素内生效，又不至于被
  /// 轻微回弹误触发。
  static const double _topToggleTravel = 36;

  /// 「管理」模式：按钮墙进入多选，可批量移除本机目录里的合集。
  ///
  /// 历史：这份列表管理能力原本在独立页 `collections_page.dart`（v1.2.0），
  /// v1.7.1 改双视图时随页面删除，只留下了"选中某合集后信息条上的单条移除"。
  /// 2026-09-22 按用户要求把列表级管理补回本视图（不恢复独立页）。
  bool _manageMode = false;

  /// 管理模式下已勾选的合集 id。
  final Set<String> _checked = <String>{};

  @override
  void initState() {
    super.initState();
    _tracker = ItemVisibilityTracker(_scroll);
    _scroll.addListener(_onContentScroll);
    // 进入本视图不再自动解析收藏动态的合集，也不再自动选中第一个合集
    // —— 收录靠 AppBar 的同步按钮，内容靠用户自己点选。
    // 首次进入弹一次说明页（只弹一次，见 [_maybeShowIntro]）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowIntro());
  }

  @override
  void didUpdateWidget(covariant FavoritesCollectionsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 收藏页整体重建（token 变化等）时跟随新 controller。
    if (oldWidget.collections != widget.collections) {
      _posts?.dispose();
      _posts = null;
      _selectedId = null;
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onContentScroll);
    _scroll.dispose();
    _posts?.dispose();
    super.dispose();
  }

  /// 内容滚动时收放顶部合集区。
  ///
  /// 收起条件：往下（内容向上走）**同向累计**滚过阈值 —— 用户在专心读内容；
  /// 展开条件：回到内容顶部（`offset <= 0`，即"在第一页继续往下拉"）
  /// 或往回累计滚过阈值 —— 用户想换合集/看列表。
  ///
  /// ⚠️ 判据是累计位移而不是单次位移：滚动回调按指针事件/帧派发，慢速滑动
  /// 单次只有几像素，逐次比阈值会表现为"必须快速甩动才响应"（2026-09-22 修）。
  ///
  /// 刻意**不判断是否正在补页**：本视图的列表是 `PagedPostList`，它的补页
  /// 补偿测的是条目相对列表自身的偏移（`viewportTopOfKey`），顶部区高度变化
  /// 只是让视口变高/变矮，不改变该偏移，因此不会产生虚假补偿量。
  /// 未选中合集（下方没有内容可浏览）时不收起 —— 那时按钮墙就是主界面。
  void _onContentScroll() {
    if (!_scroll.hasClients) return;
    final offset = _scroll.offset;
    final delta = offset - _lastContentOffset;
    _lastContentOffset = offset;
    if (_posts == null || _manageMode) return;

    // 同向累加、反向清零。
    _scrollTravel = (delta > 0) == (_scrollTravel >= 0)
        ? _scrollTravel + delta
        : delta;

    if (_topExpanded && _scrollTravel > _topToggleTravel) {
      setState(() {
        _topExpanded = false;
        _scrollTravel = 0;
      });
    } else if (!_topExpanded &&
        (offset <= 0 || _scrollTravel < -_topToggleTravel)) {
      setState(() {
        _topExpanded = true;
        _scrollTravel = 0;
      });
    }
  }

  void _select(String id) {
    final c = widget.collections.items
        .cast<FavCollection?>()
        .firstWhere((e) => e?.id == id, orElse: () => null);
    if (c == null) return;
    _posts?.dispose();
    setState(() {
      _selectedId = id;
      _posts = _createPosts(c);
      // 换合集等于换了一份内容：列表会重建、偏移归零，顶部区恢复展开，
      // 否则用户刚点完按钮墙就发现它自己收没了。
      _topExpanded = true;
      _lastContentOffset = 0;
      _scrollTravel = 0;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _posts?.ensureLoaded();
      final posts = _posts;
      if (posts == null || !mounted || posts.posts.isEmpty) return;
      // 用户已看到合集内容：清除「新动态」红点，基线推进到当前最新一条。
      await widget.collections.markSeen(id, posts.posts.first.id);
    });
  }

  CollectionPostsController _createPosts(FavCollection c) =>
      CollectionPostsController(
        tokenProvider: () => AppScope.read(context).token,
        collectionId: c.id,
        authorId: c.authorId,
        mine: widget.ownerUserId.isNotEmpty && widget.ownerUserId == c.authorId,
      )..onAuthFailure = (msg) {
          if (mounted) AppScope.read(context).markUnauthorized(msg);
        };

  void _toast(String msg) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2, milliseconds: 400),
        ),
      );
  }

  // ------------------------------------------------------------------ 管理
  // 列表级管理：多选 → 批量移除本机目录里的合集（见 [_manageMode] 的历史说明）。

  /// 点合集按钮：管理模式 → 勾选/取消勾选；普通模式 → 切换下方内容。
  void _onChipTap(String id) {
    if (!_manageMode) {
      _select(id);
      return;
    }
    setState(() {
      if (!_checked.remove(id)) _checked.add(id);
    });
  }

  void _enterManage() {
    setState(() {
      _manageMode = true;
      _checked.clear();
      // 管理时按钮墙必须整块可见，别被"滚动自动收起"藏起来。
      _topExpanded = true;
    });
  }

  void _exitManage() {
    setState(() {
      _manageMode = false;
      _checked.clear();
    });
  }

  /// 全选 / 取消全选。
  void _toggleCheckAll() {
    final all = [for (final c in widget.collections.items) c.id];
    setState(() {
      if (all.isNotEmpty && _checked.length == all.length) {
        _checked.clear();
      } else {
        _checked
          ..clear()
          ..addAll(all);
      }
    });
  }

  /// 批量移除已勾选的合集（本机侧，同单条移除的口径）。
  Future<void> _removeChecked() async {
    final ids = [
      for (final c in widget.collections.items)
        if (_checked.contains(c.id)) c.id,
    ];
    if (ids.isEmpty) {
      _toast('先勾选要移除的合集');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从本机收藏夹移除', style: TextStyle(fontSize: 17)),
        content: Text(
          '将把本机记录里的这 ${ids.length} 个合集移除。\n\n'
          '服务端没有「收藏合集」的写接口，所以这个操作只影响本机，'
          '官方端不受影响；移除后同步时也不会再自动收录它们，需要时可以恢复。',
          style: const TextStyle(fontSize: 13.5, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: Text('移除 ${ids.length} 个'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    for (final id in ids) {
      await widget.collections.remove(id);
    }
    if (!mounted) return;

    // 被移除的合集若正显示在下方，连带清掉内容 —— 否则会继续展示一个
    // 已经不在本机目录里的合集，用户再点按钮墙也选不回它。
    final removedSelected = _selectedId != null && ids.contains(_selectedId);
    if (removedSelected) _posts?.dispose();
    setState(() {
      _checked.clear();
      _manageMode = false;
      if (removedSelected) {
        _selectedId = null;
        _posts = null;
      }
    });
    _toast('已从本机收藏夹移除 ${ids.length} 个合集');
  }

  // ------------------------------------------------------------------ 同步
  // 以下操作由收藏页的 AppBar 动作经 GlobalKey 调用（对话框在视图内，
  // 因为确认文案要读 controller 的实时状态）。

  /// 同步按钮的唯一入口（AppBar 经 GlobalKey 调用）：一条命令两种口径。
  ///
  /// * **本机目录还空着**（尚未初始化）→ 完整同步：沿游标逐页翻遍全部
  ///   收藏动态，把历史上收藏过的合集一次性解析进本机目录。必须全量 ——
  ///   只抓最新 10 条常常一条合集都解析不到（历史收藏都在更早的页）。
  /// * **已有数据** → 只同步最新一页 10 条，把最近收藏里冒出来的新合集补进来。
  ///
  /// 按钮不再弹任何说明/确认框：原理与使用前提统一放在首次进入本视图的
  /// 说明页里交代（见 [_maybeShowIntro]），日常点击保持"点了就干活"。
  Future<void> syncSmart() async {
    final collections = widget.collections;
    if (collections.busy) return;
    final first = collections.items.isEmpty;

    await collections.sync(full: first);
    if (!mounted) return;

    final error = collections.error;
    if (error != null) {
      _toast('${first ? '完整解析' : '同步'}未完成：$error');
      return;
    }

    final added = collections.addedLastSync;
    final scanned = collections.scannedLastSync;
    if (first) {
      _toast(
        added > 0
            ? '已解析 $scanned 条收藏动态，收录 $added 个合集'
            : '已解析 $scanned 条收藏动态，没有发现合集 —— '
                '请先在官方客户端为收藏的合集中各收藏一条动态',
      );
      return;
    }
    _toast(
      added > 0
          ? '新收录 $added 个合集（本次解析最新 $scanned 条收藏动态）'
          : '已解析最新 $scanned 条收藏动态，没有新合集',
    );
  }

  /// 首次进入本视图时弹一次说明页。
  ///
  /// 只在「没有官方列表可读、只能由收藏动态反解」这件事上做一次交代：
  /// 用户不知道这个前提时，最容易的误解是"为什么我的收藏夹是空的"。
  /// 标记持久化在 [AppSettings.collectionsIntroShown] —— 本视图每次切走
  /// 都会销毁重建，只靠内存标记会反复弹。
  Future<void> _maybeShowIntro() async {
    if (!mounted) return;
    final settings = AppSettings.instance;
    if (settings.collectionsIntroShown) return;
    log.i(LogTag.fav, '首次进入「收藏的合集」→ 弹出一次说明页');
    // 先落标记再弹：用户中途切走/返回时不必再看一次。
    await settings.markCollectionsIntroShown();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _CollectionsIntroDialog(),
    );
  }

  /// 手动再看一次说明页（顶部工具行的常驻「说明」入口）。
  ///
  /// 与 [_maybeShowIntro] 的唯一区别：不落"已看过"标记，也不限制弹一次 ——
  /// 首次自动弹过之后，用户想再确认口径就靠这个入口。
  Future<void> _openIntro() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => const _CollectionsIntroDialog(),
    );
  }

  /// 恢复已移除的合集（下次同步解析到会重新收录）。
  Future<void> restoreRemoved() async {
    final n = widget.collections.removedCount;
    if (n == 0) return;
    await widget.collections.restoreRemoved();
    if (!mounted) return;
    _toast('已取消移除记录，下次同步会重新收录这 $n 个合集');
  }

  /// 清空本机收藏夹（回到"首次初始化"状态）。
  Future<void> clearAll() async {
    final collections = widget.collections;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空本机收藏夹', style: TextStyle(fontSize: 17)),
        content: Text(
          '将删除本机记录的 ${collections.length} 个合集'
          '（含 ${collections.removedCount} 条移除记录）。'
          '下一次进入本视图会重新从收藏动态里解析。',
          style: const TextStyle(fontSize: 13.5, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await collections.clearAll();
    if (!mounted) return;
    _posts?.dispose();
    setState(() {
      _selectedId = null;
      _posts = null;
    });
    _toast('已清空本机收藏夹');
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    // 需求调整：不再自动选中第一个合集 —— 未点击前只显示按钮墙与提示，
    // 下方不出现任何合集内容。
    return AnimatedBuilder(
      animation: widget.collections,
      builder: (context, _) => Column(
        children: [
          // 顶部固定区：状态条 + 合集按钮墙。浏览内容时会自动收起，回到内容
          // 顶部再展开（见 [_onContentScroll]）；AnimatedSize 让高度平滑过渡，
          // 收起/展开只改变视口高度，不动内容的坐标系。
          ClipRect(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: (_topExpanded || _manageMode)
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _topArea(),
                        const Divider(height: 0.6),
                      ],
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ),
          // 内容区：选中合集的动态流。
          Expanded(child: _content()),
        ],
      ),
    );
  }

  Widget _topArea() {
    final collections = widget.collections;
    final items = collections.items;

    return Container(
      color: AppTheme.cardBackground,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (items.isNotEmpty) ...[
            _toolRow(),
            const SizedBox(height: 7),
          ],
          _statusBar(),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                collections.phase == LoadPhase.loadingFirst
                    ? (collections.progress ?? '正在同步收藏动态，解析合集…')
                    : '还没有收录任何合集 —— 点右上角同步按钮开始解析。',
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.inkTertiary,
                  height: 1.55,
                ),
              ),
            )
          else ...[
            if (_manageMode) ...[
              _manageBar(),
              const SizedBox(height: 8),
            ],
            _chipWall(items),
          ],
        ],
      ),
    );
  }

  /// 顶部工具行：左侧标题与「说明」入口，右侧「管理 / 完成」。
  ///
  /// 「说明」是常驻入口（首次进入的那次自动弹出只弹一次，之后想再看只能靠它）。
  Widget _toolRow() {
    final n = widget.collections.items.length;
    return Row(
      children: [
        Expanded(
          child: Text(
            '收藏的合集（$n）',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.inkPrimary,
            ),
          ),
        ),
        _textAction(
          label: '说明',
          icon: Icons.help_outline_rounded,
          color: AppTheme.inkTertiary,
          onTap: _openIntro,
        ),
        const SizedBox(width: 10),
        _textAction(
          label: _manageMode ? '完成' : '管理',
          icon: _manageMode
              ? Icons.done_rounded
              : Icons.checklist_rtl_rounded,
          color: AppTheme.accent,
          onTap: _manageMode ? _exitManage : _enterManage,
        ),
      ],
    );
  }

  Widget _textAction({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13.5, color: color),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 管理模式的操作条：已选数量 + 全选 + 移除。
  Widget _manageBar() {
    final total = widget.collections.items.length;
    final allChecked = total > 0 && _checked.length == total;
    return Row(
      children: [
        Text(
          _checked.isEmpty ? '勾选要移除的合集' : '已选 ${_checked.length} 个',
          style: TextStyle(fontSize: 12.5, color: AppTheme.inkSecondary),
        ),
        const Spacer(),
        TextButton(
          onPressed: _toggleCheckAll,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            allChecked ? '取消全选' : '全选',
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
        const SizedBox(width: 6),
        FilledButton(
          onPressed: _checked.isEmpty ? null : _removeChecked,
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            backgroundColor: AppTheme.danger,
            foregroundColor: Colors.white,
          ),
          child: Text(
            _checked.isEmpty ? '移除' : '移除 ${_checked.length} 个',
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
      ],
    );
  }

  /// 合集按钮墙：所有合集渲染成缩小按钮，点选切换下方内容。
  Widget _chipWall(List<FavCollection> items) {
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: [
        for (final c in items) _chip(c),
      ],
    );
  }

  Widget _chip(FavCollection c) {
    final checked = _manageMode && _checked.contains(c.id);
    // 管理模式下的"选中"是勾选，与"当前正在看哪个合集"无关，两者互斥显示。
    final selected = !_manageMode && _selectedId == c.id;
    final emphasized = selected || checked;
    final isNew = widget.collections.lastAddedIds.contains(c.id);
    final bg = emphasized ? AppTheme.accent : AppTheme.surfaceMuted;

    return InkWell(
      onTap: () => _onChipTap(c.id),
      onLongPress: _manageMode ? null : () => _toggleSubscribe(c),
      borderRadius: BorderRadius.circular(15),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: emphasized ? AppTheme.accent : AppTheme.divider,
            width: 0.6,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _manageMode
                  ? (checked
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked)
                  : Icons.collections_bookmark_outlined,
              size: 12,
              color: emphasized ? Colors.white70 : AppTheme.inkTertiary,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                c.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: emphasized ? Colors.white : AppTheme.inkPrimary,
                  fontWeight: emphasized ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            // 名称右侧恒定预留订阅铃铛位：订阅状态变化（长按切换、
            // 新收录的合集被订阅）时按钮宽度不变，Wrap 墙不会闪烁重排。
            // 未订阅时放一个等宽占位 —— 不需要数据迁移，新旧合集统一生效。
            const SizedBox(width: 3),
            if (c.subscribed)
              Icon(
                Icons.notifications_active_rounded,
                size: 11.5,
                color: emphasized ? Colors.white : AppTheme.accent,
              )
            else
              const SizedBox(width: 11.5),
            // 订阅扫描发现新动态：名称右侧红点（点开合集后清除）。
            if (c.hasNew) ...[
              const SizedBox(width: 4),
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: emphasized ? Colors.white : AppTheme.danger,
                  shape: BoxShape.circle,
                ),
              ),
            ],
            if (c.postsCount >= 0) ...[
              const SizedBox(width: 3),
              Text(
                '${c.postsCount}',
                style: TextStyle(
                  fontSize: 10.5,
                  color: emphasized ? Colors.white70 : AppTheme.inkTertiary,
                ),
              ),
            ],
            if (isNew) ...[
              const SizedBox(width: 4),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 3, vertical: 0.5),
                decoration: BoxDecoration(
                  color: selected
                      ? Colors.white.withValues(alpha: 0.25)
                      : AppTheme.successBackground,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  '新',
                  style: TextStyle(
                    fontSize: 9,
                    color: emphasized ? Colors.white : AppTheme.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 同步状态条（迁移自原收藏夹页）。
  Widget _statusBar() {
    final collections = widget.collections;
    if (collections.busy) {
      final progress = collections.progress;
      return _banner(
        background: AppTheme.infoBackground,
        child: Row(
          children: [
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                progress ??
                    (collections.fullSyncing
                        ? '正在完整同步收藏动态…'
                        : '正在同步最新的收藏动态…'),
                style:
                    TextStyle(fontSize: 12, color: AppTheme.accent),
              ),
            ),
          ],
        ),
      );
    }

    final error = collections.error;
    if (error != null) {
      return _banner(
        background: AppTheme.warningBackground,
        border: AppTheme.warningBorder,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '本次同步失败，下面展示的是本机已收录的内容。',
              style: TextStyle(
                fontSize: 12.5,
                color: AppTheme.warning,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              error,
              style: TextStyle(
                fontSize: 11.5,
                color: AppTheme.warning,
                height: 1.5,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                // 重试复刻用户刚才那一次操作：目录空 → 完整解析，有数据 → 最新 10 条。
                onPressed: collections.busy ? null : () => syncSmart(),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('重试', style: TextStyle(fontSize: 12.5)),
              ),
            ),
          ],
        ),
      );
    }

    final notice = collections.syncNotice;
    if (notice == null) return const SizedBox(height: 2);
    return _banner(
      background: AppTheme.infoBackground,
      child: Row(
        children: [
          Icon(Icons.auto_awesome_outlined,
              size: 13, color: AppTheme.accent),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              notice,
              style: TextStyle(fontSize: 12, color: AppTheme.accent),
            ),
          ),
        ],
      ),
    );
  }

  Widget _banner({
    required Color background,
    required Widget child,
    Color? border,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(9),
        border:
            border == null ? null : Border.all(color: border, width: 0.6),
      ),
      child: child,
    );
  }

  Widget _noSelection() {
    final hasItems = widget.collections.items.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Text(
          hasItems ? '点击上方的合集按钮，在下方查看它的内容' : '还没有可展示的合集',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            color: AppTheme.inkTertiary,
            height: 1.6,
          ),
        ),
      ),
    );
  }

  Widget _content() {
    final posts = _posts;
    if (posts == null) return _noSelection();

    return AnimatedBuilder(
      animation: posts,
      builder: (context, _) {
        if (posts.phase == LoadPhase.loadingFirst && posts.posts.isEmpty) {
          return const LoadingView(message: '正在拉取合集内容…');
        }
        if (posts.phase == LoadPhase.error && posts.posts.isEmpty) {
          return ErrorView(
            message: posts.error ?? '加载失败',
            onRetry: posts.retry,
          );
        }
        if (posts.isEmptyResult) {
          return const EmptyView(
            icon: Icons.inbox_outlined,
            title: '这个合集里还没有内容',
          );
        }

        // PagedPostList 没有处理 controller 更换（listener 挂在 initState），
        // 换合集时必须让它整棵重建，ValueKey 兜住。
        return PagedPostList(
          key: ValueKey(_selectedId),
          controller: posts,
          scrollController: _scroll,
          tracker: _tracker,
          header: _selectedHeader(),
          itemBuilder: (context, post, index) => PostCard(
            post: post,
            isRead: posts.isReadAt(index),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                  builder: (_) => PostDetailPage(post: post)),
            ),
            onVote: (target) async {
              final ok = await toggleVote(context, post);
              if (ok) posts.applyVote(post.id, post.isVoted);
            },
            onFavourite: (target) async {
              final ok = await toggleFavourite(context, post);
              if (ok) posts.applyFavourite(post.id, post.isFavourited);
            },
          ),
        );
      },
    );
  }

  /// 选中合集的信息条：名称 / 条数 / 作者 + 移除入口。
  Widget _selectedHeader() {
    final c = widget.collections.items
        .cast<FavCollection?>()
        .firstWhere((e) => e?.id == _selectedId, orElse: () => null);
    if (c == null) return const SizedBox.shrink();

    return Container(
      color: AppTheme.cardBackground,
      padding: const EdgeInsets.fromLTRB(14, 9, 8, 9),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.inkPrimary,
                  ),
                ),
                if (c.description.isNotEmpty ||
                    c.authorName.isNotEmpty ||
                    c.postsCount >= 0) ...[
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (c.postsCount >= 0) '${c.postsCount} 条内容',
                      if (c.authorName.isNotEmpty) '作者 ${c.authorName}',
                      if (c.description.isNotEmpty) c.description,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.inkTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: c.subscribed
                ? '取消订阅（冷启动不再检查该合集）'
                : '订阅此合集（冷启动时检查新动态，也可长按上方按钮切换）',
            onPressed: () => _toggleSubscribe(c),
            icon: Icon(
              c.subscribed
                  ? Icons.notifications_active_rounded
                  : Icons.notifications_none_rounded,
              size: 18,
            ),
            color: c.subscribed ? AppTheme.accent : AppTheme.inkDisabled,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            padding: EdgeInsets.zero,
          ),
          IconButton(
            tooltip: '从本机移除该合集',
            onPressed: () => _remove(c),
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            color: AppTheme.inkDisabled,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  Future<void> _remove(FavCollection c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从本机收藏夹移除', style: TextStyle(fontSize: 17)),
        content: Text(
          '「${c.name}」将从本软件里移除。\n\n'
          '服务端没有「收藏合集」的写接口，所以这个操作只影响本机，'
          '官方端不受影响；移除后同步时也不会再自动收录它，需要时可以恢复。',
          style: const TextStyle(fontSize: 13.5, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.collections.remove(c.id);
    if (!mounted) return;
    if (_selectedId == c.id) {
      _posts?.dispose();
      setState(() {
        _selectedId = null;
        _posts = null;
      });
    }
    _toast('已从本机收藏夹移除「${c.name}」');
  }

  // -------------------------------------------------------------- 订阅

  /// 切换订阅状态。订阅后每次冷启动会串行扫描该合集有无新动态，
  /// 有则在按钮墙该合集名称右侧显示红点。
  ///
  /// 订阅值必须从仓库里现读：手势回调里握着的 [c] 是上一帧渲染时的
  /// 旧对象，若直接 `!c.subscribed`，在界面还没重建时连点两下会
  /// 两次都算出"要订阅"，表现为只能订阅、取消不了。
  Future<void> _toggleSubscribe(FavCollection c) async {
    final fresh = widget.collections.byId(c.id) ?? c;
    final target = !fresh.subscribed;
    await widget.collections.setSubscribed(c.id, target);
    if (!mounted) return;
    _toast(target
        ? '已订阅「${fresh.name}」，冷启动时会检查新动态'
        : '已取消订阅「${fresh.name}」');
  }
}

/// 「收藏的合集」首次进入时的说明页（只弹一次）。
///
/// 必须交代的前提（界面文案不出现端点与技术词）：
/// 1. 官方不提供「我收藏的合集」这份列表 → 本机目录不可能是"同步"下来的；
/// 2. 它只能由**已收藏的动态**反解而来：动态属于哪个合集，哪个合集才被收录；
/// 3. 因此使用前要回到官方客户端，为每个收藏的合集收藏至少一条动态；
/// 4. 然后点右上角同步按钮，首次会翻遍全部收藏动态；
/// 5. 解析完成后，那些**为了解析而临时收藏的动态可以取消收藏** —— 合集已经
///    落到本机目录里，不会因为动态被取消收藏而消失（2026-09-22 用户要求补入）。
class _CollectionsIntroDialog extends StatelessWidget {
  const _CollectionsIntroDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('收藏的合集是怎么来的', style: TextStyle(fontSize: 17)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            _IntroPoint(
              icon: Icons.info_outline_rounded,
              text: '官方客户端没有「我收藏的合集」这份列表可以读取，'
                  '所以这里的合集是从你收藏过的动态里解析出来的：'
                  '动态属于哪个合集，那个合集就会被收录进本机列表，'
                  '之后可以正常翻阅。',
            ),
            _IntroPoint(
              icon: Icons.playlist_add_check_rounded,
              text: '使用前请先回到官方客户端，进入收藏的合集，'
                  '为每个合集收藏至少一条动态，否则解析不出任何合集。',
              highlight: true,
            ),
            _IntroPoint(
              icon: Icons.sync_rounded,
              text: '然后回到这里点右上角的同步按钮：首次会翻遍全部收藏动态'
                  '（需要一点时间），之后每次只同步最新 10 条。',
            ),
            _IntroPoint(
              icon: Icons.bookmark_remove_outlined,
              text: '为了解析而临时收藏的动态，解析完合集之后可以取消收藏，'
                  '不会影响已经解析出来的合集列表。',
            ),
            _IntroPoint(
              icon: Icons.notifications_active_rounded,
              text: '合集还能订阅：点选一个合集后按信息条上的铃铛'
                  '（或长按上方的合集按钮）即可订阅，之后每次打开软件会自动'
                  '检查它的新动态，有更新就在合集名旁标红点；'
                  '再点一次铃铛取消订阅。',
              last: true,
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    );
  }
}

/// 说明页里的一条分点。
class _IntroPoint extends StatelessWidget {
  const _IntroPoint({
    required this.icon,
    required this.text,
    this.highlight = false,
    this.last = false,
  });

  final IconData icon;
  final String text;

  /// 关键前提（"先在官方端为每个合集收藏一条动态"）用强调色，
  /// 避免被略读跳过。
  final bool highlight;

  /// 最后一条不再留底边距。
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              icon,
              size: 15,
              color: highlight ? AppTheme.warning : AppTheme.accent,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.8,
                height: 1.62,
                color: highlight ? AppTheme.warning : AppTheme.inkSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
