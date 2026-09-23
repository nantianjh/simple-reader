import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../api/models.dart';
import '../../state/load_phase.dart';
import '../../state/paged_list.dart';
import '../../util/app_log.dart';
import '../theme.dart';
import 'read_tracker.dart';

/// 分页式内容瀑布流。
///
/// 与无限瀑布流的行为差异：
/// * 内容按页组织，每页 [ApiConfig.defaultPerPage] 条，页边界在列表里可见；
/// * 滑到当前页最后一条再往上滑 → 抓下一页，接在末尾；
/// * 回到当前页第一条再往下滑 → 抓上一页，接在开头，并做滚动偏移补偿，
///   使原来的第一条留在原处（两侧首尾相连，画面不跳）。
class PagedPostList extends StatefulWidget {
  const PagedPostList({
    super.key,
    required this.controller,
    required this.scrollController,
    required this.tracker,
    required this.itemBuilder,
    this.header,
    this.enableRefresh = true,
  });

  final PagedListController controller;
  final ScrollController scrollController;
  final ItemVisibilityTracker tracker;

  /// 单条内容的外部包装（负责点击、点赞等交互）。
  final Widget Function(BuildContext context, Post post, int index) itemBuilder;

  /// 固定在列表上方的条幅（缓存提示、一次性提示等）。
  final Widget? header;

  final bool enableRefresh;

  @override
  State<PagedPostList> createState() => _PagedPostListState();
}

class _PagedPostListState extends State<PagedPostList> {
  /// 距底部多近开始抓下一页（取固定值与视口比例中的较大者）。
  ///
  /// 用固定像素在竖屏手机上够用，但大屏/平板一屏更高，260px 只占屏高很小
  /// 一部分，容易出现"一路滑到底却没触发"。改成跟着视口走。
  double get _nextTrigger {
    final h = widget.scrollController.hasClients
        ? widget.scrollController.position.viewportDimension
        : 0.0;
    return math.max(260, h * 0.5);
  }

  /// 距顶部多近开始抓上一页。
  double get _prevTrigger {
    final h = widget.scrollController.hasClients
        ? widget.scrollController.position.viewportDimension
        : 0.0;
    return math.max(120, h * 0.35);
  }

  /// 一屏都装不满时最多自动补几页，避免服务端异常时无限补。
  static const int _maxAutoFill = 5;

  Timer? _debounce;
  bool _prepending = false;
  bool _filling = false;
  int _fillRounds = 0;

  /// 补页校正窗口内临时放大的 cacheExtent（"探照灯"，P1-A）。
  ///
  /// 默认 cacheExtent（250px）只把视口外一小段纳入布局；向上补页会把
  /// 锚点条目顶出 3000~9000px 远，锚点不被布局 → 实测失败 → 只能退
  /// max 增量兜底，而该兜底拿"平均条目高 × 剩余条数"的**估计值**当 Δ，
  /// 实机误差可达千 px（2026-09-20 探针实测：校正后 46~90ms 内 max 摆动
  /// +703 / −6013px，摆动量≈画面跳变量）。补页期间把它临时放大到足以
  /// 覆盖一整页 + 视口，插入页与锚点全部真实布局，锚点实测
  /// （localToGlobal）路径即可用。粗校正完成即恢复默认（保险丝见
  /// `_loadPrevPage` 的 finally）；代价是那一帧多布局十几张卡片
  /// （缓存页 + NetImage 定尺寸，单帧开销可接受，仅向上补页时发生）。
  static const double _kCorrectionCacheExtent = 16000;
  double? _correctionCacheExtent;

  /// 补页"定格帧"：把旧画面截成静态图盖在列表上，遮蔽插入帧（防闪烁）。
  ///
  /// 背景（2026-09-20 22:02 实机复测）：锚点实测上线后窗口不再跳，但仍
  /// "闪一下"。根因是帧序硬约束 —— 校正 jumpTo 只能发生在 postFrame
  /// 回调（绘制之后），Flutter 没有"布局后、绘制前"的公开钩子，所以
  /// 「新页进入布局的那一帧」必然先于校正被画出来：视口 offset 仍是旧值，
  /// 画出的却是新页顶部（Δ≈2554px 的整屏内容互换），直到下一帧才被
  /// jumpTo 拉回。探测灯那一帧本身很重（要布局整页新卡片），显示时长
  /// 50~150ms，肉眼可见。同样帧序原因，多列表接力（隐藏副本量 Δ）也不
  /// 可行 —— 条目挂着共享 tracker 的 GlobalKey，第二份实时副本必撞
  /// duplicate key。
  ///
  /// 做法：prevPage 成功后、插入帧绘制前，用 RepaintBoundary.toImageSync
  /// 把"最后画出的旧画面"同步截成位图，盖在列表上（IgnorePointer 不挡
  /// 手势）；粗校正落地即撤 —— 撤下那一帧的画面与定格帧逐像素一致，
  /// 闪烁全程被遮蔽。校正窗口内用户继续滚动的分量由锚点校正口径自动
  /// 扣除（见 _loadPrevPage 方法头），松手惯性场景同样成立。
  ui.Image? _freezeFrame;

  /// 挂在列表外层 [RepaintBoundary] 上，供定格帧截屏取层。
  final GlobalKey _listBoundaryKey = GlobalKey();

  // ---- 诊断探针（2026-09-20 复测仍跳变临时加入，定位后移除）----
  /// guard 静默出口留痕去重：同一原因 1 秒内只打一条（_onScroll 每帧
  /// 都可能进来，不去重会淹没日志）。
  String _lastGuardSkip = '';
  DateTime _lastGuardSkipAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 带落地校验的 jumpTo：jumpTo 同步写 pixels，落地值与目标不一致
  /// 说明有别的写入者在同一同步段里覆盖了偏移（探针核心证据）。
  void _jumpWithProbe(ScrollController scroll, double target, String tag) {
    final pre = scroll.offset;
    scroll.jumpTo(target);
    final landed = scroll.offset;
    if ((landed - target).abs() > 0.5) {
      log.w(
        LogTag.page,
        '[$tag] jumpTo 未按预期落地：目标 ${target.toStringAsFixed(1)}，'
        '实际 ${landed.toStringAsFixed(1)}（写入前 ${pre.toStringAsFixed(1)}）'
        '—— 偏移被同步覆盖',
      );
    }
  }

  /// 截取列表当前画面作定格帧（同步，[RenderRepaintBoundary.toImageSync]
  /// 内部对层调 `OffsetLayer.toImageSync`，返回时位图即可用，不等下一帧
  /// 光栅化）。失败返回 null，调用方静默退回原路径 —— 只损失"防闪烁"，
  /// 不引入新问题。
  ui.Image? _captureListFrame() {
    try {
      final ro = _listBoundaryKey.currentContext?.findRenderObject();
      if (ro is! RenderRepaintBoundary) return null;
      // 必须已上树、已布局、且本帧无需重绘：前两条保证 layer 存在，第三条
      // 保证 layer 里装的确实是"上一帧画出来的旧画面"而不是更早/空内容
      // （toImageSync 自己也 assert 这一条；注意该判断在 release 下恒为
      // false，故这里只是让 debug 不走异常路径，不是 release 的安全网）。
      if (!ro.attached || !ro.hasSize || ro.debugNeedsPaint) return null;
      final dpr = MediaQuery.devicePixelRatioOf(context);
      return ro.toImageSync(pixelRatio: dpr);
    } catch (_) {
      return null;
    }
  }

  /// 撤掉定格帧并释放位图（幂等；早退路径由 finally 保险丝兜底）。
  void _clearFreezeFrame() {
    final img = _freezeFrame;
    if (img == null) return;
    _freezeFrame = null;
    img.dispose();
    if (mounted) setState(() {});
  }

  /// 上一次写入续读点的位置（条目 + 页号 + 页内序号），用于去重。
  String _lastCheckedPosition = '';

  /// 待恢复的滚动锚点：条目 id / 它在视口内的位置 / 最多再校正几帧。
  ///
  /// 条目高度会因「展开全文 / 收起 / 整条折叠」而变化，变化后列表会把下方
  /// 内容整体上推或下拉（`ListView` 只保证第一个已布局子项的偏移，不做
  /// 通用锚定），观感就是"画面猛地一跳"。这里的做法是：高度将变时先记下
  /// 视口里最靠上的那条，布局完成后再把它的视口内位置还原。
  Object? _anchorId;
  double? _anchorTop;
  int _anchorRounds = 0;

  /// 锚定时刻的滚动偏移。与 [_anchorTop] 相加 = 锚点条目在列表内容坐标
  /// 系里的位置 —— 那是个不随后续布局变化的不变量，折叠把条目整个挤出
  /// 视口时（见 [_restoreAnchor] 的回收分支）靠它直接定位。
  double? _anchorOffset;

  /// 锚点条目恢复后期望的视口内位置。
  ///
  /// null = 维持原位（默认，恢复逻辑按"变化前后视口内位置一致"校正）；
  /// 0 = 折叠后收回到视口顶端：长文浏览到中部时折叠，发起条目顶部已在
  /// 视口上方，若仍按原位恢复，框架会把下一个条目顶到视口顶端，观感是
  /// "整屏内容被抽走"。
  double? _anchorTargetTop;

  /// 上一次锚定校正后的滚动偏移。用来识别"用户在这几帧里自己滚了"。
  double? _anchorAppliedOffset;

  /// 单次高度变化的锚定校正最多跨几帧（卡片高度变化可能连带触发自动补页）。
  static const int _maxAnchorRounds = 3;

  PagedListController get _ctl => widget.controller;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
    _ctl.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoFill());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.scrollController.removeListener(_onScroll);
    _ctl.removeListener(_onControllerChanged);
    // 定格帧位图若还挂着（极端时序：补页未走完组件就下树），随 State 释放。
    _freezeFrame?.dispose();
    _freezeFrame = null;
    super.dispose();
  }

  // ---------------------------------------------------------------- 触发点

  void _onControllerChanged() {
    if (!mounted) return;
    _scheduleVisibilityCheck();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoFill());
  }

  void _onScroll() {
    if (!widget.scrollController.hasClients) return;
    final pos = widget.scrollController.position;
    // 触底补下一页、触顶补上一页。
    //
    // 这里刻意**不判断滑动方向**：方向是"用户手上动作"的信息，而补页只
    // 取决于"视口离哪一端更近"。加上方向判断只会漏触发（例如已经在底部
    // 再往上滑、或程序滚动到位后用户接着滑）。
    //
    // 补页（_prepending）期间不接受新的补页请求：那一侧正在做"记录锚点 →
    // 插入内容 → 还原锚点"的多步操作，中途再插一次补页会让两次补偿互相
    // 抵消，表现为长距离跳动。
    if (!_prepending) {
      if (pos.maxScrollExtent - pos.pixels < _nextTrigger) {
        _ctl.nextPage();
      } else if (pos.pixels < _prevTrigger) {
        _loadPrevPage();
      }
    }
    _scheduleVisibilityCheck();
  }

  /// 触底/触顶时位移已经不再变化，ScrollController 的监听器不会触发，
  /// 只有 OverscrollNotification 会继续派发 —— 「已经在底部再往上滑」
  /// 正是这种情况，必须靠它才能补页。
  bool _onScrollNotification(ScrollNotification n) {
    if (n is OverscrollNotification) {
      final m = n.metrics;
      if (n.overscroll > 0 && m.maxScrollExtent - m.pixels < _nextTrigger) {
        _ctl.nextPage();
      } else if (n.overscroll < 0 && m.pixels < _prevTrigger) {
        _loadPrevPage();
      }
    } else if (n is ScrollEndNotification) {
      // 惯性滚动正好停在两端时不会产生 overscroll，这里补一次判定。
      final m = n.metrics;
      // 滚动停止的这一刻就是"最后停留位置"最可靠的采样点：不等 260ms 的
      // 防抖，直接记一次。否则"滚完立刻退出"会把最后的位置丢掉。
      _checkVisibilityNow();
      // 内容收缩（收起/折叠）后 maxScrollExtent 变小，框架会把越界的偏移
      // 拉回来 —— 这是一次用户没做任何操作的"位置跳变"，出现时必须留痕，
      // 否则事后只能靠肉眼复现。
      if (m.maxScrollExtent >= 0 && m.pixels > m.maxScrollExtent + 1) {
        log.w(
          LogTag.ui,
          '滚动位置越界回弹：offset=${m.pixels.toStringAsFixed(1)} '
          '> max=${m.maxScrollExtent.toStringAsFixed(1)}',
        );
      }
      if (!_prepending) {
        if (m.maxScrollExtent > 0 && m.maxScrollExtent - m.pixels < 1) {
          _ctl.nextPage();
        } else if (m.pixels < 1 && m.maxScrollExtent > 0) {
          _loadPrevPage();
        }
      }
    }
    return false;
  }

  /// 抓上一页，并把视口按「锚点位置的变化」整体校正。
  ///
  /// 补偿口径的演进（两条都对应过"滑动时偶现长距离跳动"）：
  /// 1. 早期用"maxScrollExtent 的增量"当作上方新增的高度。这在"上方条目
  ///    高度恒定"时成立；一旦上方某条正文被展开/收起，增量里就混进了高度
  ///    变化量，校正过度或不足。现在改为锚定**视口里最靠上的已渲染条目**，
  ///    取它补页前后的视口内偏移之差，与 maxScrollExtent 无关；
  /// 2. 更隐蔽的一条：补偿必须叠加在**当前**偏移上。补一页要走一次网络
  ///    （限速下至少 1.2 秒），用户在这 1.2 秒里继续滑动是常态 —— 若用
  ///    "补页前的偏移 + 补偿量"回写，用户刚滑出去的距离会被一次性撤销，
  ///    表现为毫无征兆的长距离跳回。这里用的是 `scroll.offset`（当前值），
  ///    数学上等价于按内容坐标补偿，用户滚动不会被吃掉。
  /// 3. 补页多在 overscroll 拉伸动画进行中触发，`settleFrame` 可能先于
  ///    「含新数据的帧」返回，量到旧布局会把补偿误判为无事可做（Δ=0
  ///    静默跳过）—— 布局回来后必须校验 max 已变化，没变就再等帧
  ///    （见实现内注释与 [waitFreshPagedLayout]）。
  /// 跳页落地保护：程序化滚动（跳页回顶）期间为 true。
  ///
  /// 跳页把窗口收敛到目标页后要把视口拉回列表顶端，而"视口在顶端"恰好是
  /// 「补上一页」的触发条件 —— 但此刻布局还没跟上控制器的隔离结果，锚点
  /// 在重排后会落到 cacheExtent 之外测不到（delta=null），max 增量兜底又
  /// 因 beforeMax 取自陈旧布局而算出 0，补偿必然失效，实测跳到第 2 页会
  /// 落在第 1 页。程序化滚动期间跳过补页，把机会留给用户的真实滚动
  /// （那时布局与数据一致，补页窗口内放大的 cacheExtent 让锚点实测可用）。
  bool _inProgrammaticScroll = false;

  Future<void> _loadPrevPage() async {
    // _anchorId 非空 = 折叠/展开的锚定校正还在跨帧进行，它也在写偏移；
    // 这时再插入补页补偿，两次写入会互相叠加成长距离跳动。
    if (_inProgrammaticScroll ||
        _prepending ||
        _ctl.busy ||
        _anchorId != null ||
        !_ctl.hasPrevPage) {
      // 探针：静默出口留痕（同因 1s 去重，避免滚动帧刷屏）。
      final reason = !_ctl.hasPrevPage
          ? '无上一页可补'
          : _inProgrammaticScroll
              ? '程序化滚动中'
              : _prepending
                  ? '上次补页未结束'
                  : _ctl.busy
                      ? '控制器忙'
                      : '折叠锚定中';
      final now = DateTime.now();
      if (reason != _lastGuardSkip ||
          now.difference(_lastGuardSkipAt).inMilliseconds > 1000) {
        _lastGuardSkip = reason;
        _lastGuardSkipAt = now;
        log.d(LogTag.page, '补上一页跳过：$reason');
      }
      return;
    }
    final scroll = widget.scrollController;
    if (!scroll.hasClients) return;
    _prepending = true;
    try {
      final beforeMax = scroll.position.maxScrollExtent;
      final beforeOffset = scroll.offset;
      // 锚点先取好：补页后列表顶部会多出上一页，用 id 定位才稳定。
      final ids = <Object>[
        for (final p in _ctl.posts) p.id,
      ];
      final anchor = widget.tracker.firstVisibleKey(ids);
      final anchorTop =
          anchor == null ? null : widget.tracker.viewportTopOfKey(anchor);

      final ok = await _ctl.prevPage();
      if (!ok) {
        log.d(LogTag.page,
            '补上一页失败：prevPage 未成功（无上页或抓取失败），放弃本次补页');
        return;
      }

      // ---- 定格帧（防闪烁）：抢在插入帧绘制前截下旧画面 ----
      // prevPage 内部是"合入数据 → notify → 返回"，中间不 await 帧；
      // notify 排上的那一帧此刻还没绘制，所以这里同步截屏拿到的正是用户
      // 眼前这幅旧画面。盖上它（build 里随本次重建一起上树），插入帧
      // 对用户不可见；粗校正落地后撤（见下方 _clearFreezeFrame）。
      _freezeFrame ??= _captureListFrame();
      if (_freezeFrame != null) {
        log.d(LogTag.page, '定格帧：已截取列表画面，遮蔽补页插入帧');
      } else {
        log.d(LogTag.page, '定格帧不可用：截屏失败，按原路径继续（可能闪一帧）');
      }

      // ---- 开探照灯（P1-A）：校正窗口内放大 cacheExtent ----
      // 默认 250px 的布局范围罩不住一整页（数千 px），锚点会被顶出布局、
      // 实测失败，只能退不可信的 max 兜底 —— 实机长期如此（2026-09-20
      // 探针实锤两次补页都走兜底且 Δ 失准）。先放大再等布局，插入页与
      // 锚点全部真实布局，锚点实测路径即可用。
      if (mounted && _correctionCacheExtent == null) {
        setState(() => _correctionCacheExtent = _kCorrectionCacheExtent);
      }

      // 等列表按新数据完成布局，再校正偏移，使锚点留在原处。
      //
      // settleFrame 等的是「当前已经在跑的这一帧」。补页几乎总在 overscroll
      // 拉伸动画进行中触发（手指顶在列表顶端，系统每一帧都在重绘），
      // endOfFrame 可能先于「含新数据的帧」返回 —— 这时量到的还是旧布局：
      // max 无增量、锚点无位移，补偿被判为无事可做而**静默跳过**，下一帧
      // 新页整体落下，视口上方凭空多出约一页高度，表现为长距离跳变
      // （实测 2026-09-19：跳页落顶后向上补页必跳、连续补页一跳一不跳，
      // 均此成因）。所以布局回来后必须校验「插入已生效」再测量。
      //
      // 判据分两路（P1-C）：有锚点基线时以「锚点 top 位移」为准 —— 那是
      // 插入生效的直接证据；max 是"平均条目高 × 剩余条数"的估计值，动画
      // 期间的回收/重估也能让它变化（实测 90ms 内摆动 6013px），把噪声
      // 误判为已落库会导致量到未位移的锚点、Δ=0 跳过、新页随后落下即
      // 跳变。无锚点基线时退回 max 判据（waitFreshPagedLayout）。
      await settleFrame();
      if (!mounted || !scroll.hasClients) return;
      final bool fresh;
      if (anchor != null && anchorTop != null) {
        final anchorId = anchor;
        fresh = await waitAnchorLanded(
          readTop: () => widget.tracker.viewportTopOfKey(anchorId),
          topBefore: anchorTop,
          waitFrame: settleFrame,
          onWait: (round) => log.d(
            LogTag.page,
            '补页后布局未含新数据（锚点 top 未位移），再等一帧（第 ${round + 1} 轮）',
          ),
        );
      } else {
        fresh = await waitFreshPagedLayout(
          readMax: () => scroll.position.maxScrollExtent,
          beforeMax: beforeMax,
          waitFrame: settleFrame,
          onWait: (round) => log.d(
            LogTag.page,
            '补页后布局未含新数据（max='
            '${scroll.position.maxScrollExtent.toStringAsFixed(1)} 未变），'
            '再等一帧（第 ${round + 1} 轮）',
          ),
        );
      }
      if (!mounted || !scroll.hasClients) return;
      if (!fresh) {
        // 等满上限仍无位移：新页大概率被跨页去重/本地过滤整页吃掉，
        // 上方真的什么都没插入，本就无需补偿 —— 留痕，别静默。
        log.d(
          LogTag.page,
          '补页校正放弃：连续多帧布局无变化'
          '（新页可能被去重/过滤整页吃掉），'
          'max=${scroll.position.maxScrollExtent.toStringAsFixed(1)}',
        );
        return;
      }

      // ---- 粗校正：把视口拉回锚点附近 ----
      // 探照灯开着（上面已放大 cacheExtent），插入页与锚点都在布局范围
      // 内，正常情况下走「锚点实测」：Δ = 补页前后锚点视口 top 之差，
      // 是 localToGlobal 实测值，与任何估计无关。仅当锚点仍测不到时
      // （页高超出探照灯预算 / 锚点被跨页去重吃掉）才退 max 增量近似 ——
      // 注意那是"整窗净增长"的**估计值**：maxScrollExtent = 已布局条目
      // 平均高 × 剩余条数，实机条目高差异大时误差可达千 px（2026-09-20
      // 探针实测两事件：应用 Δ 后 46~90ms 内 max 又摆动 +703 / −6013px，
      // 摆动量即画面跳变量），且会掺入锚点**下方**的新增行（跳页入口行
      // 随 pageCount 变化出现，实测残余 355.6px）。兜底只保证接近，残差
      // 交给精校正与守卫；该路径本身要在日志里显眼可辨。
      double? delta;
      String source = 'max-增量兜底·估计值';
      if (anchor != null && anchorTop != null) {
        final after = widget.tracker.viewportTopOfKey(anchor);
        if (after != null) {
          delta = after - anchorTop;
          source = '锚点实测';
        }
      }
      if (delta == null) {
        // 锚点在探照灯范围内仍找不到 —— 页高超出预算，或跨页去重把它
        // 吃掉（服务端插入新内容后相邻页出现同一条，`_rebuild` 会从
        // **下方的页**里删重）。此时 maxScrollExtent 的减小只反映视口之外
        // 的内容收缩，按负增量校正会把用户直接甩到列表顶部（实测
        // Δ≈-7748px、offset→0）。所以：max 增大（上方真插入了内容）才用
        // 增量近似补偿；max 持平或缩小就放弃这次补偿 —— 视口外的收缩
        // 本来就不影响当前画面，错误补偿的代价远大于不补偿。
        final maxDelta = scroll.position.maxScrollExtent - beforeMax;
        delta = maxDelta > 0 ? maxDelta : 0.0;
      }
      if (delta.abs() < 0.5) {
        // 走到这里的 Δ≈0 只剩「锚点前后位置没变」一种（布局新鲜度已在
        // 上面保证）。过去这里是静默 return，排障时无从下手 —— 三份实机
        // 日志里的无痕跳变正来自这类静默出口，所有放弃路径统一留痕。
        log.d(
          LogTag.page,
          '补页校正跳过：Δ≈0（锚点=${anchor ?? 'max-增量'}，'
          'max ${beforeMax.toStringAsFixed(1)} → '
          '${scroll.position.maxScrollExtent.toStringAsFixed(1)}）',
        );
        return;
      }

      final target =
          (scroll.offset + delta).clamp(0.0, scroll.position.maxScrollExtent);
      if ((target - scroll.offset).abs() < 0.5) {
        log.d(
          LogTag.page,
          '补页校正跳过：Δ 被列表边界吸收'
          '（offset=${scroll.offset.toStringAsFixed(1)}，'
          'max=${scroll.position.maxScrollExtent.toStringAsFixed(1)}）',
        );
        return;
      }
      log.d(
        LogTag.page,
        '补上一页后校正滚动：锚点=${anchor ?? '无'}（$source），'
        'Δ=${delta.toStringAsFixed(1)}px，'
        'offset ${beforeOffset.toStringAsFixed(1)} → '
        '${target.toStringAsFixed(1)}（max ${beforeMax.toStringAsFixed(1)} → '
        '${scroll.position.maxScrollExtent.toStringAsFixed(1)}）',
      );
      _jumpWithProbe(scroll, target, '补页粗校正');

      // ---- 关探照灯：粗校正完成，恢复默认 cacheExtent ----
      // 锚点此刻应已回到视口顶，默认范围即可实测；恢复引发的回收只涉及
      // 视口外条目（SliverList 的 GC 校正保持可见内容不动），画面不受
      // 影响。恢复后的布局由下方精校正与守卫在"生产条件"下兜底验证。
      if (mounted && _correctionCacheExtent != null) {
        setState(() => _correctionCacheExtent = null);
      }

      // ---- 撤定格帧：粗校正已落地，下一帧画面与定格帧逐像素一致 ----
      // 本 setState 与上面的关探照灯合并为同一次重建；下一帧绘制的就是
      // 校正后画面，遮罩撤下的瞬间无缝衔接（残余由精修与守卫负责，
      // 锚点实测路径下残差≈0）。截屏失败时这里是空操作。
      _clearFreezeFrame();

      // ---- 精校正：实测锚点残余位移并修掉 ----
      // 粗校正后锚点已进入（或接近）cacheExtent，可以实测了。残余来源：
      // 粗校正的增量近似掺入了锚点下方内容的净变化。用同一套"叠加在当前
      // offset"的口径修掉（数学上对用户中途滚动自洽：delta 自动扣除滚动
      // 量，见方法头注释第 2 点）。上限 2 轮，残差归零即提前退出。
      for (var round = 0;
          round < 2 && anchor != null && anchorTop != null;
          round++) {
        await settleFrame();
        if (!mounted || !scroll.hasClients) return;
        final after = widget.tracker.viewportTopOfKey(anchor);
        if (after == null) {
          log.w(
            LogTag.page,
            '补页校正精修放弃（第 ${round + 1} 轮）：锚点=$anchor 未渲染'
            '（offset=${scroll.offset.toStringAsFixed(1)}，'
            'max=${scroll.position.maxScrollExtent.toStringAsFixed(1)}）'
            '—— 粗校正可能存在残差且无法实测',
          );
          break;
        }
        final residual = after - anchorTop;
        if (residual.abs() < 0.5) break;
        final fixed = (scroll.offset + residual)
            .clamp(0.0, scroll.position.maxScrollExtent);
        if ((fixed - scroll.offset).abs() < 0.5) break;
        log.d(
          LogTag.page,
          '补页校正精修（第 ${round + 1} 轮）：锚点=$anchor，'
          '残余 Δ=${residual.toStringAsFixed(1)}px，'
          'offset ${scroll.offset.toStringAsFixed(1)} → '
          '${fixed.toStringAsFixed(1)}',
        );
        _jumpWithProbe(scroll, fixed, '补页精修');
      }

      // ---- 校正后守卫 + 自愈（P1-B）----
      // 观察若干帧：锚点视口 y 的变化若恰好等于 offset 的反向变化量，
      // 说明只是用户自己在滚（合法，静默）；扣除用户滚动后仍偏离 >2px
      // 属异常漂移 —— 正常情况下不应存在（探照灯已关、锚点应在视口顶），
      // 直接把**异常分量**修回（自愈公式：jump 量 = abnormal，用户的
      // 滚动量保留不动），修完重置基线继续观察；2 次修不收敛或锚点被
      // 顶出视口则报警留痕。
      var heals = 0;
      if (anchor != null && anchorTop != null) {
        var guardOffset0 = scroll.offset;
        for (var g = 0; g < 4; g++) {
          await settleFrame();
          if (!mounted || !scroll.hasClients) return;
          final now = widget.tracker.viewportTopOfKey(anchor);
          if (now == null) {
            log.w(
              LogTag.page,
              '校正后守卫（第 ${g + 1} 帧）：锚点=$anchor 已不在视口内'
              '（offset=${scroll.offset.toStringAsFixed(1)}，'
              'max=${scroll.position.maxScrollExtent.toStringAsFixed(1)}）'
              '—— 校正后被顶出',
            );
            break;
          }
          final drift = now - anchorTop;
          final userScroll = scroll.offset - guardOffset0;
          final abnormal = drift + userScroll; // 扣除用户自身滚动分量
          if (abnormal.abs() <= 2) continue;
          if (heals < 2) {
            final healed = (scroll.offset + abnormal)
                .clamp(0.0, scroll.position.maxScrollExtent);
            if ((healed - scroll.offset).abs() > 0.5) {
              heals++;
              log.w(
                LogTag.page,
                '校正后自愈（第 $heals 次）：锚点=$anchor 异常漂移 '
                '${abnormal.toStringAsFixed(1)}px（总漂移 '
                '${drift.toStringAsFixed(1)}，用户滚动 '
                '${userScroll.toStringAsFixed(1)}），'
                'offset ${scroll.offset.toStringAsFixed(1)} → '
                '${healed.toStringAsFixed(1)}',
              );
              _jumpWithProbe(scroll, healed, '补页守卫自愈');
              guardOffset0 = scroll.offset;
              continue;
            }
          }
          log.w(
            LogTag.page,
            '校正后锚点漂移未收敛（第 ${g + 1} 帧）：锚点=$anchor，'
            '预期 top=${anchorTop.toStringAsFixed(1)}，'
            '实测 ${now.toStringAsFixed(1)}，'
            '异常 ${abnormal.toStringAsFixed(1)}px（自愈已用 $heals/2 次）'
            '—— 校正落地后另有写入者或上方内容变化',
          );
          break;
        }
      }
      log.d(
        LogTag.page,
        '补上一页收尾：路径=$source，Δ=${delta.toStringAsFixed(1)}px，'
        '最终 offset=${scroll.offset.toStringAsFixed(1)}'
        '（max=${scroll.position.maxScrollExtent.toStringAsFixed(1)}），'
        '守卫=${heals > 0 ? '自愈 $heals 次' : '通过'}',
      );
    } finally {
      _prepending = false;
      // 探照灯保险丝：任何早退路径（放弃/跳过/异常）都不能把放大的
      // cacheExtent 留在列表上，否则常驻多布局一大段视口外内容。
      if (_correctionCacheExtent != null && mounted) {
        setState(() => _correctionCacheExtent = null);
      }
      // 定格帧保险丝：同上，放弃/跳过/异常路径也不能把静态遮罩留在
      // 列表上（幂等，正常路径已撤时这里是空操作）。
      _clearFreezeFrame();
    }
  }

  /// 内容不足约 1.5 屏时自动补页。
  ///
  /// 两个原因：内容不够一屏时列表根本不接受拖拽（ClampingScrollPhysics 在
  /// min==max 时忽略手势），用户会看到"怎么滑都没反应"；内容刚过一屏时
  /// 也没有预取空间，下一页要等滑到底才抓。补到有余量为止（有次数上限，
  /// 避免服务端异常时无限补）。
  void _autoFill() {
    if (!mounted || _filling) return;
    if (_prepending) return; // 补上一页的锚点校正还没结束，别插队
    final scroll = widget.scrollController;
    if (!scroll.hasClients) return;
    final pos = scroll.position;
    if (pos.viewportDimension <= 0) return; // 还没完成布局
    if (pos.maxScrollExtent > pos.viewportDimension * 0.5) {
      _fillRounds = 0;
      return;
    }
    if (_ctl.busy || !_ctl.hasNextPage) return;
    // 续读会话缓存读完：不再自动补页（cacheOnly 必然未命中，纯浪费读盘）。
    if (_ctl.offlineReading && !_ctl.hasNextCachedPage) return;
    if (_fillRounds >= _maxAutoFill) return;
    _fillRounds++;
    _filling = true;
    _ctl.nextPage().whenComplete(() => _filling = false);
  }

  /// 滚动停止后判定「最后停留的位置」，写入续读点。
  ///
  /// 取的是"最后一个完整显示在视口内"的条目：它是一次停留的稳定锚点，
  /// 恢复时把这一条滚到视口顶部即可接着读。
  ///
  /// 注意这里**不再判断是否已读** —— 续读点的语义是「最后停在哪」，
  /// 往回翻到已读内容上同样要更新（旧实现因为"序号没前进"直接丢弃，
  /// 于是往回翻之后续读点仍停在更靠后的位置）。
  void _scheduleVisibilityCheck() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 260), _checkVisibilityNow);
  }

  /// 立刻判定一次「最后停留的位置」并写入续读点。
  ///
  /// 由两处触发：滚动停止（[ScrollEndNotification]，最可靠的采样点）与
  /// 260ms 防抖到期。防抖是为了避免滚动过程中频繁落盘，但**不能**当作唯一
  /// 入口 —— 用户停在某处后立刻退出，防抖还没到就丢了这次位置。
  void _checkVisibilityNow() {
    if (!mounted) return;
    final ids = <Object>[
      for (final p in _ctl.posts) p.id,
    ];
    final id = widget.tracker.lastFullyVisibleKey(ids);
    if (id == null) return;
    final index = _ctl.indexOfPostId(id.toString());
    if (index < 0) return;

    // 位置（条目 + 页号 + 页内序号）没变就不重复写：滚动停止时这条会被
    // ScrollEnd 与 260ms 防抖各触发一次，加上写入本身会 notifyListeners，
    // 去重后整页列表的无效重建与磁盘写入都能省掉一半。
    final key = '${id}_${_ctl.pageOfItem(index)}_${_ctl.offsetInPage(index)}';
    if (key == _lastCheckedPosition) return;
    _lastCheckedPosition = key;
    _ctl.notePosition(index);
  }

  // -------------------------------------------------------- 高度变化锚定

  /// 条目高度**将要**变化时由卡片调用（展开/收起正文、整条折叠）。
  ///
  /// 记下当前视口里最靠上的已渲染条目，等布局完成后把它的视口内位置还原；
  /// 否则高度一变，下方内容会被整体推走，观感就是"大幅度跳跃"。
  ///
  /// [willShrink]：高度是否将变小（折叠/收起）；[itemId]：发起变化的
  /// 条目 id。两者合起来处理一种默认锚定罩不住的情形——**长文浏览到
  /// 中部时折叠**：发起条目就是视口最靠上的条目，但它的顶部已滚出视口
  /// （top < 0），折叠后只剩一行摘要，"维持原位"不再有意义。此时期望的
  /// 恢复位置改为视口顶端，让折叠摘要完整地停在最上面、下方内容跟上来
  /// （见 [_restoreAnchor]）。
  void anchorItemHeightChange(bool willShrink, String? itemId) {
    final scroll = widget.scrollController;
    if (!scroll.hasClients) return;
    final ids = <Object>[
      for (final p in _ctl.posts) p.id,
    ];
    final anchor = widget.tracker.firstVisibleKey(ids);
    if (anchor == null) return;
    final top = widget.tracker.viewportTopOfKey(anchor);
    if (top == null) return;
    _anchorId = anchor;
    _anchorTop = top;
    _anchorOffset = scroll.offset;
    _anchorTargetTop = null;
    _anchorRounds = 0;
    _anchorAppliedOffset = null;
    if (willShrink &&
        itemId != null &&
        itemId.isNotEmpty &&
        itemId == anchor.toString() &&
        top < -0.5) {
      // 长文浏览到中部时折叠：发起条目就是视口最靠上的条目，且它的顶部
      // 已滚出视口。折叠后这一条只剩一行摘要，若维持当前偏移，条目会整体
      // 滚出 cacheExtent——不止观感问题：元素被列表回收重建后，卡片本地的
      // 折叠/展开状态会全部丢失（实测表现为"折叠又弹回六行"）。
      //
      // 解法是**预跳**：在 setState 生效前（同一个手势回调、同一帧）把
      // 滚动偏移先定位到条目的内容坐标，让条目顶部停到视口顶端。高度
      // 变化落地时条目就在视口内，不会被回收；视觉上也只有一个帧——
      // 用户读到的中部文字与折叠动作同帧消失，没有中间态。
      _anchorTargetTop = 0;
      final target =
          (scroll.offset + top).clamp(0.0, scroll.position.maxScrollExtent);
      if ((target - scroll.offset).abs() >= 0.5) {
        log.d(
          LogTag.ui,
          '折叠预跳：$itemId 顶部已滚出视口（${top.toStringAsFixed(1)}），'
          '滚动 ${scroll.offset.toStringAsFixed(1)} → ${target.toStringAsFixed(1)}，'
          '折叠摘要将停在视口顶端',
        );
        scroll.jumpTo(target);
        _anchorOffset = target;
        _anchorTop = 0;
        _anchorAppliedOffset = target;
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreAnchor());
  }

  /// 把锚点条目放回它期望的视口位置（默认原位，折叠收回场景为视口顶端）。
  ///
  /// 一帧往往不够：高度变化可能连带触发 `_autoFill` 补页或布局二次调整，
  /// 因此允许再校正几帧（上限 [_maxAnchorRounds]）。
  ///
  /// **关键安全阀**：多帧校正期间只要发现滚动偏移被改成"不是我上一次写进去
  /// 的值"，就说明用户自己动了手（或别的代码改了偏移）—— 立刻放弃本次锚定。
  /// 否则下一帧会把用户的滚动量当成"内容布局变化"再补偿一次，
  /// 等于把用户刚滑出去的距离又拽回来，正是"偶现长距离跳动"的成因。
  void _restoreAnchor() {
    if (!mounted) return;
    final scroll = widget.scrollController;
    final id = _anchorId;
    final before = _anchorTop;
    if (id == null || before == null || !scroll.hasClients) return;

    final applied = _anchorAppliedOffset;
    if (applied != null && (scroll.offset - applied).abs() > 1) {
      log.d(
        LogTag.ui,
        '锚定校正放弃：期间滚动偏移被外部改变（'
        '${applied.toStringAsFixed(1)} → ${scroll.offset.toStringAsFixed(1)}）',
      );
      _anchorId = null;
      _anchorAppliedOffset = null;
      return;
    }

    final after = widget.tracker.viewportTopOfKey(id);
    if (after == null) {
      // 锚点条目没有渲染出来。折叠场景下的典型成因：条目收缩后整体滚到了
      // 视口上方，框架把下一个条目顶到视口顶端（内容坐标守恒，但视口里
      // 已经全是别的内容）。此时期望位置是"视口顶端"（_anchorTargetTop
      // 已在锚定时刻记下），直接把偏移定位到锚点条目的内容坐标
      // （锚定时刻 offset + top，不随布局变化），折叠摘要就停在最上面。
      final anchorOffset = _anchorOffset;
      if (_anchorTargetTop != null && anchorOffset != null && before < 0) {
        final target = (anchorOffset + before)
            .clamp(0.0, scroll.position.maxScrollExtent);
        if ((target - scroll.offset).abs() >= 0.5) {
          log.d(
            LogTag.ui,
            '折叠后锚点滚出视口 → 收回视口顶端：$id 滚动 '
            '${scroll.offset.toStringAsFixed(1)} → ${target.toStringAsFixed(1)}',
          );
          scroll.jumpTo(target);
          _anchorAppliedOffset = target;
        }
        if (_anchorRounds < _maxAnchorRounds) {
          _anchorRounds++;
          WidgetsBinding.instance.addPostFrameCallback((_) => _restoreAnchor());
          return;
        }
      }
      _anchorId = null;
      _anchorAppliedOffset = null;
      return; // 锚点已渲染不出来（例如被滚动回收），放弃这次校正
    }
    final targetTop = _anchorTargetTop ?? before;
    final delta = after - targetTop;
    if (delta.abs() < 0.5) {
      _anchorId = null;
      _anchorAppliedOffset = null;
      return;
    }

    final target =
        (scroll.offset + delta).clamp(0.0, scroll.position.maxScrollExtent);
    if ((target - scroll.offset).abs() >= 0.5) {
      log.d(
        LogTag.ui,
        '条目高度变化 → 锚定校正：$id 偏移 ${before.toStringAsFixed(1)} → '
        '${after.toStringAsFixed(1)}，滚动 ${scroll.offset.toStringAsFixed(1)} → '
        '${target.toStringAsFixed(1)}（第 ${_anchorRounds + 1} 帧）',
      );
      scroll.jumpTo(target);
      _anchorAppliedOffset = target;
    }

    if (_anchorRounds < _maxAnchorRounds) {
      _anchorRounds++;
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreAnchor());
    } else {
      _anchorId = null;
      _anchorAppliedOffset = null;
    }
  }

  // -------------------------------------------------------- 条目删除补偿

  /// 本次删除补偿的现场（见 [anchorItemRemoval] / [_restoreAfterRemoval]）。
  String? _removalId;

  /// 参考条目 id 与它在**删除前**的视口内位置。
  Object? _removalRefId;
  double? _removalRefTop;

  int _removalRounds = 0;
  double? _removalAppliedOffset;

  /// 删除补偿最多再校正几帧（删除会连带重排「上次浏览到这儿」分界）。
  static const int _maxRemovalRounds = 2;

  /// 条目**即将从列表里删除**时的滚动补偿入口。
  ///
  /// 为什么不能复用 [anchorItemHeightChange]：那条路径的锚点条目自己留在列表
  /// 里，靠"把它放回原视口位置"收尾；而删除会让锚点条目消失，补偿无从谈起
  /// —— 用户实测：收藏的动态展开成长文后取消收藏，画面整段跳走
  /// （2026-09-22 报，见《关注按钮与评论图片与取消收藏跳动-探查报告》第 3 节）。
  ///
  /// 做法分两步，都在同一帧内完成，用户看不到中间态：
  /// 1. **预测式预跳**：删掉一条只会让**它下方**的内容整体上移它的高度，
  ///    所以先把滚动偏移减去这个高度。高度取"被删条目"与"其后继条目"的
  ///    **实测内容坐标差**（含卡片间距，不靠估计）；删除的是最后一条时无需
  ///    补偿（下方没有内容）。
  /// 2. 删除落地后由 [_restoreAfterRemoval] 量残差补上预跳没覆盖的部分。
  ///
  /// ⚠️ 调用方必须在**修改数据之前**调用本方法（同一个同步块）。
  void anchorItemRemoval(String itemId) {
    final scroll = widget.scrollController;
    if (!scroll.hasClients) return;
    final posts = _ctl.posts;
    final i = posts.indexWhere((p) => p.id == itemId);
    if (i < 0) return;

    _finishRemoval();
    _removalId = itemId;

    // 参考条目：视口里最靠上的、**不是被删的那一条** —— 删除后要让它回到
    // 删除前的位置，这样被删条目下方的内容就纹丝不动。
    final refIds = <Object>[
      for (final p in posts)
        if (p.id != itemId) p.id,
    ];
    _removalRefId = widget.tracker.firstVisibleKey(refIds);
    _removalRefTop = _removalRefId == null
        ? null
        : widget.tracker.viewportTopOfKey(_removalRefId!);

    double? shift;
    if (i + 1 < posts.length) {
      final removedTop = widget.tracker.offsetOfKey(itemId);
      final nextTop = widget.tracker.offsetOfKey(posts[i + 1].id);
      if (removedTop != null && nextTop != null) shift = nextTop - removedTop;
    }
    if (shift == null || shift <= 0) {
      log.d(LogTag.ui, '删除条目无需预跳：$itemId（无后继或高度测不到）');
    } else {
      final target =
          (scroll.offset - shift).clamp(0.0, scroll.position.maxScrollExtent);
      if ((target - scroll.offset).abs() >= 0.5) {
        log.i(
          LogTag.ui,
          '删除条目预跳：$itemId 高度约 ${shift.toStringAsFixed(1)}px，'
          '滚动 ${scroll.offset.toStringAsFixed(1)} → '
          '${target.toStringAsFixed(1)}',
        );
        _jumpWithProbe(scroll, target, '删除预跳');
        _removalAppliedOffset = target;
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreAfterRemoval());
  }

  /// 删除落地后量残差：把参考条目放回它删除前的视口位置。
  ///
  /// 预跳覆盖的是"被删条目自身的高度"；删除还会重算「上次浏览到这儿」分界，
  /// 分界条跨过视口时也有几十像素的位移。这里用参考条目的实测位移补齐 ——
  /// 预跳准确时残差为 0，等于什么都不做。
  ///
  /// **安全阀**与 [_restoreAnchor] 同口径：期间偏移被外部改过（用户自己滚了）
  /// 就立刻放弃，避免把用户的滑动量当布局漂移再补偿一次。
  void _restoreAfterRemoval() {
    if (!mounted) return;
    final scroll = widget.scrollController;
    final removedId = _removalId;
    final refId = _removalRefId;
    final refTopBefore = _removalRefTop;
    if (removedId == null || refId == null || refTopBefore == null) {
      _finishRemoval();
      return;
    }
    if (!scroll.hasClients) {
      _finishRemoval();
      return;
    }

    final applied = _removalAppliedOffset;
    if (applied != null && (scroll.offset - applied).abs() > 1) {
      log.d(LogTag.ui, '删除补偿放弃：期间滚动偏移被外部改变');
      _finishRemoval();
      return;
    }

    final after = widget.tracker.viewportTopOfKey(refId);
    if (after == null) {
      // 参考条目还没渲染出来（重建后的懒构建）→ 再等一帧。
      if (_removalRounds < _maxRemovalRounds) {
        _removalRounds++;
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _restoreAfterRemoval());
        return;
      }
      log.d(LogTag.ui, '删除补偿放弃：参考条目 $refId 未能渲染');
      _finishRemoval();
      return;
    }

    final delta = after - refTopBefore;
    if (delta.abs() >= 0.5) {
      final target =
          (scroll.offset + delta).clamp(0.0, scroll.position.maxScrollExtent);
      if ((target - scroll.offset).abs() >= 0.5) {
        log.i(
          LogTag.ui,
          '删除后残差校正：参考 $refId 视口位置 '
          '${refTopBefore.toStringAsFixed(1)} → ${after.toStringAsFixed(1)}，'
          '滚动 ${scroll.offset.toStringAsFixed(1)} → '
          '${target.toStringAsFixed(1)}',
        );
        _jumpWithProbe(scroll, target, '删除残差');
        _removalAppliedOffset = target;
      }
    }

    if (_removalRounds < _maxRemovalRounds) {
      _removalRounds++;
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreAfterRemoval());
    } else {
      _finishRemoval();
    }
  }

  void _finishRemoval() {
    _removalId = null;
    _removalRefId = null;
    _removalRefTop = null;
    _removalRounds = 0;
    _removalAppliedOffset = null;
  }

  // -------------------------------------------------------------- 指定跳页

  /// 跳页入口是否可用。
  ///
  /// 两种口径：
  /// * **续读（缓存）会话**：可跳范围是「上次缓存的所有页」（存档里的
  ///   缓存深度），与本次已浏览多少页无关 —— 上次缓存了 9 页，本次哪怕
  ///   停在第 3 页，入口也要放行 1–9；
  /// * **普通会话**：沿用「只能在已加载的页之间跳」的既有口径，只拉取
  ///   第 1 页时没有可跳的去处，入口整体隐藏。
  bool get _jumpAvailable {
    if (_ctl.offlineReading) {
      final deep = _ctl.cachedDeepPage;
      if (deep >= 0) return deep >= 1; // 缓存 ≥ 2 页才有得跳
      return _ctl.pageCount >= 2; // 深度未知：退回已加载口径
    }
    return _ctl.pageCount >= 2;
  }

  /// 弹窗输入页号后跳转。
  ///
  /// 普通会话目标页必须是**已加载**的页（弹窗里已限制），跳转不发任何
  /// 请求；续读会话目标页可以直接寻址（游标链已恢复），只读本地缓存加载，
  /// 缓存意外缺失时由 [PagedListController.jumpToPage] 落回联网一次。
  Future<void> _askJumpPage() async {
    final ctl = _ctl;
    final offline = ctl.offlineReading && ctl.cachedDeepPage >= 0;
    final first = offline ? 1 : (ctl.firstPage ?? 0) + 1;
    final last = offline
        ? ctl.cachedDeepPage + 1
        : (ctl.lastPage ?? 0) + 1;
    if (last - first + 1 < 2) return; // 入口已隐藏，这里双保险

    final intro = offline
        ? '上次缓存共 $last 页（第 1–$last 页），可跳到其中任意一页。\n'
            '跳转后列表只保留目标页，向上/向下滚动即可从本地缓存补回相邻的页。'
        : null;

    final page = await showDialog<int>(
      context: context,
      builder: (ctx) => _JumpPageDialog(first: first, last: last, intro: intro),
    );

    if (page == null || page < 1 || !mounted) return;
    final target = page - 1;
    log.i(
      LogTag.ui,
      '请求跳转到第 $page 页（${offline ? '缓存范围 1–$last' : '已加载范围内'}）',
    );
    final ok = await ctl.jumpToPage(target);
    if (!mounted) return;

    if (!ok) {
      log.w(LogTag.ui, '跳转到第 $page 页失败：${ctl.error ?? '未知原因'}');
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(ctl.error ?? '无法跳到第 $page 页'),
        ));
      return;
    }

    // 跳页落地：先让"窗口收敛到目标页"的布局落一帧（此刻 pixels 会被钳到
    // 新 max），再把视口定位到目标页顶端。顺序颠倒会让"补上一页"在我们
    // 自己的回顶 jumpTo 上触发——布局与数据错位时锚定补偿必然失效，
    // 实测跳到第 2 页会落在第 1 页（见 _inProgrammaticScroll 的说明）。
    await settleFrame();
    if (!mounted) return;
    final scroll = widget.scrollController;
    _inProgrammaticScroll = true;
    try {
      if (scroll.hasClients) {
        scroll.jumpTo(0);
      }
    } finally {
      _inProgrammaticScroll = false;
    }
    _fillRounds = 0;
    log.i(LogTag.ui, '已停在第 $page 页（视口回到列表顶端）');
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final ctl = _ctl;
    // 「上次浏览到这儿」分界：新抓取内容之后的第一条旧内容前插一条标识。
    final boundary = ctl.cachedBoundary;
    // 跳页入口只在「已加载 ≥ 2 页」时出现（需求：只能跳已加载的范围）。
    final jumpAvailable = _jumpAvailable;
    final rows = <_Row>[];
    var global = 0;
    for (final page in ctl.pages) {
      rows.add(_Row.pageHeader(page.index));
      for (final post in page.items) {
        if (global == boundary) rows.add(const _Row.marker());
        rows.add(_Row.post(post, global));
        global++;
      }
      // 页尾跳页入口：每一页的最后一条之后都放一个，无论用户停在哪一页，
      // 页首（页眉）与页尾各有一个入口可点。
      if (jumpAvailable) rows.add(const _Row.jumpTail());
    }
    rows.add(const _Row.footer());

    // RepaintBoundary 供定格帧截屏（_captureListFrame）：补页防闪烁用，
    // 平时把列表的 repaint 与页面其余部分隔离，本身无副作用。
    final list = RepaintBoundary(
      key: _listBoundaryKey,
      child: ListView.separated(
      controller: widget.scrollController,
      // 补页校正窗口内临时放大（探照灯，见 _correctionCacheExtent）；
      // null = Flutter 默认（250px）。
      // 用 scrollCacheExtent 而非已废弃的 cacheExtent（v3.41 起）：两者严格
      // 等价 —— ScrollView.build 内部就是 ScrollCacheExtent.pixels(cacheExtent)，
      // 故"向外多布局 16000px"的探照灯语义不变。
      scrollCacheExtent: _correctionCacheExtent == null
          ? null
          : ScrollCacheExtent.pixels(_correctionCacheExtent!),
      padding: const EdgeInsets.only(bottom: 18),
      itemCount: rows.length,
      separatorBuilder: (context, i) {
        // 页眉与页脚自带上间距，不再叠分隔线；分界条自带两侧拉线，
        // 跳页入口自带上下留白，同样不叠。
        final next = rows[i + 1];
        if (next.isHeader || next.isFooter || next.isMarker || next.isJumpTail) {
          return const SizedBox.shrink();
        }
        if (rows[i].isMarker || rows[i].isJumpTail) {
          return const SizedBox.shrink();
        }
        return const Padding(
          padding: EdgeInsets.only(left: 14),
          child: Divider(height: 0.6),
        );
      },
      itemBuilder: (context, i) {
        final row = rows[i];
        if (row.isFooter) return _footer(ctl);
        if (row.isHeader) return _pageHeader(row.page);
        if (row.isMarker) return _cachedBoundaryMarker();
        if (row.isJumpTail) return _jumpTailRow();
        final post = row.post!;
        return KeyedSubtree(
          key: widget.tracker.keyFor(post.id),
          child: Container(
            color: AppTheme.cardBackground,
            child: widget.itemBuilder(context, post, row.index),
          ),
        );
      },
      ),
    );

    return PagedPostListAnchor(
      onHeightWillChange: anchorItemHeightChange,
      onItemWillBeRemoved: anchorItemRemoval,
      child: Column(
        children: [
          if (widget.header != null) widget.header!,
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  widget.enableRefresh
                      ? RefreshIndicator(
                          onRefresh: () => ctl.refresh(),
                          child: list,
                        )
                      : list,
                  // 定格帧遮罩：补页校正窗口内盖住列表区域（IgnorePointer
                  // 不挡手势，用户的滚动/惯性照常传到下面的实时列表）；
                  // 撤下时画面已与插入前逐像素一致，插入帧全程不可见。
                  if (_freezeFrame != null)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: RawImage(
                          image: _freezeFrame,
                          fit: BoxFit.fill,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 「上次浏览到这儿」分界条：插在新抓取内容与上次已缓存内容之间，
  /// 提示"从这里往下是上次已经浏览过的"。
  Widget _cachedBoundaryMarker() {
    return Container(
      color: AppTheme.cardBackground,
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.history_rounded,
                    size: 12.5, color: AppTheme.inkTertiary),
                const SizedBox(width: 4),
                Text(
                  '上次浏览到这儿',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.inkTertiary,
                  ),
                ),
              ],
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }

  /// 页边界。分页式瀑布流要让"一页"看得见，否则与无限流无异。
  ///
  /// 页眉就是**当页页首的跳页入口**：可跳时整条可点（带上下箭头提示），
  /// 只有 1 页（无处可跳）时退化为纯文本。
  Widget _pageHeader(int page) {
    final available = _jumpAvailable;
    return Container(
      color: AppTheme.cardBackground,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 9),
      child: Center(
        child: InkWell(
        onTap: available ? _askJumpPage : null,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '第 ${page + 1} 页',
                style: TextStyle(
                  fontSize: 11.5,
                  color: AppTheme.inkTertiary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (available) ...[
                const SizedBox(width: 3),
                Icon(Icons.unfold_more_rounded,
                    size: 13, color: AppTheme.inkTertiary),
              ],
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _footer(PagedListController ctl) {
    if (ctl.busy) {
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
    if (ctl.phase == LoadPhase.error && ctl.error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
        child: Column(
          children: [
            Text(
              ctl.error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppTheme.danger),
            ),
            TextButton(onPressed: ctl.retry, child: const Text('重新加载')),
          ],
        ),
      );
    }
    // 续读（缓存）会话的页脚：本地缓存已经读完（下一页没有缓存可翻）时，
    // 不再显示「继续上滑或点此加载」——那句话在缓存模式下是空承诺
    // （cacheOnly 不会发请求，加载不出任何东西），改为指路搜索按钮。
    // 缓存还有下一页时维持原提示（上滑确实能从缓存补出那一页）。
    if (ctl.offlineReading && !ctl.hasNextCachedPage) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: Text(
            '上次缓存内容已阅读完，请点击搜索按钮加载新内容',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              color: AppTheme.inkTertiary,
              height: 1.5,
            ),
          ),
        ),
      );
    }
    if (ctl.hasNextPage) {
      // 也可点击：手势触发之外再留一条确定能用的补页路径。
      // （跳页入口在每页页尾，见 [_jumpTailRow]，这里不再重复放。）
      return InkWell(
        onTap: ctl.busy ? null : () => ctl.nextPage(),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Center(
            child: Text(
              '继续上滑或点此加载第 ${(ctl.lastPage ?? 0) + 2} 页',
              style: TextStyle(
                fontSize: 12.5,
                color: AppTheme.accent,
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Text(
          ctl.pageCount > 1
              ? '已是最后一页 · 共 ${ctl.itemCount} 条'
              : '已加载完 · 共 ${ctl.itemCount} 条',
          style: TextStyle(fontSize: 12.5, color: AppTheme.inkTertiary),
        ),
      ),
    );
  }

  /// 当页页尾的跳页入口：每一页最后一条之后都放一个，
  /// 与页眉（[_pageHeader]）一上一下各一次。
  Widget _jumpTailRow() {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 14),
      child: Center(
        child: InkWell(
          onTap: _askJumpPage,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.skip_next_rounded,
                    size: 14, color: AppTheme.inkTertiary),
                const SizedBox(width: 4),
                Text(
                  '跳至指定页',
                  style: TextStyle(fontSize: 12, color: AppTheme.inkTertiary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 等列表布局真正包含补页数据（max 相对 [beforeMax] 发生变化）。
///
/// 背景：补页的触发点多在 overscroll 拉伸动画进行中，紧随其后的那一次
/// `settleFrame`（endOfFrame）可能先于「含新数据的帧」返回。若不校验，
/// 就会用旧布局算出 Δ=0 并静默放弃补偿，下一帧新页整体落下即长距离跳变。
///
/// 返回 true = 布局已含新页（或至少 max 已变，可安全测量）；
/// 返回 false = 等满 [maxRounds] 仍无变化 —— 新页大概率被跨页去重/本地
/// 过滤整页吃掉，上方没有插入内容，本就无需补偿。
///
/// [readMax]/[waitFrame] 注入以便单测；生产路径分别取
/// `scroll.position.maxScrollExtent` 与 [settleFrame]。
@visibleForTesting
Future<bool> waitFreshPagedLayout({
  required double Function() readMax,
  required double beforeMax,
  required Future<void> Function() waitFrame,
  int maxRounds = 3,
  void Function(int round)? onWait,
}) async {
  for (var round = 0; round < maxRounds; round++) {
    if (readMax() != beforeMax) return true;
    onWait?.call(round);
    await waitFrame();
  }
  return readMax() != beforeMax;
}

/// 等补页数据真正落进布局：新页插在锚点上方，锚点的视口 top 必然位移。
///
/// 旧判据「max 相对 beforeMax 变化」建立在估计值上 —— maxScrollExtent 是
/// 「已布局条目平均高 × 剩余条数」的估计，overscroll 动画期间的回收与
/// 重估同样能让它变化（2026-09-20 实测：校正窗口内 90ms 摆动 6013px），
/// 存在把估计噪声误判为「已落库」、随后量到未位移锚点的风险。锚点 top
/// 位移是插入生效的直接证据；调用方须保证锚点在布局范围内（配合补页
/// 窗口内放大的 cacheExtent，见 `_kCorrectionCacheExtent`）。
///
/// 返回 true = 锚点已位移（插入已生效，可安全测量补偿量）；
/// 返回 false = 等满 [maxRounds] 锚点仍原地 —— 新页大概率被跨页去重/
/// 本地过滤整页吃掉，上方没有插入内容，本就无需补偿。
///
/// [readTop]/[waitFrame] 注入以便单测。
@visibleForTesting
Future<bool> waitAnchorLanded({
  required double? Function() readTop,
  required double topBefore,
  required Future<void> Function() waitFrame,
  int maxRounds = 4,
  void Function(int round)? onWait,
}) async {
  bool landed() {
    final top = readTop();
    return top != null && (top - topBefore).abs() > 0.5;
  }

  for (var round = 0; round < maxRounds; round++) {
    if (landed()) return true;
    onWait?.call(round);
    await waitFrame();
  }
  return landed();
}

/// 「跳至指定页」弹窗。
///
/// 做成 StatefulWidget 是刻意的：TextEditingController 由它自己持有并在
/// `dispose()` 里释放 —— 对话框确认/取消后还有一段退出动画，动画期间
/// 输入框仍挂载（键盘收起还会触发重建），若在外层 await 返回后立刻
/// dispose，InputDecorator 重建时会撞上 "used after being disposed"。
/// 挂在 State 上的资源要等路由完全卸载才会走到 dispose，天然避开。
class _JumpPageDialog extends StatefulWidget {
  const _JumpPageDialog({required this.first, required this.last, this.intro});

  /// 可跳页号范围（1 起，含两端）。
  final int first;
  final int last;

  /// 说明文案。缺省按「已加载范围」口径生成；续读（缓存）会话传入
  /// 「上次缓存范围」口径，避免沿用"已加载 N 页"这种不符的表述。
  final String? intro;

  @override
  State<_JumpPageDialog> createState() => _JumpPageDialogState();
}

class _JumpPageDialogState extends State<_JumpPageDialog> {
  late final TextEditingController _input = TextEditingController(text: '1');
  String? _error;

  void _submit() {
    final v = int.tryParse(_input.text.trim());
    if (v == null || v < widget.first || v > widget.last) {
      setState(() => _error = '请输入 ${widget.first}–${widget.last} 之间的页号');
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('跳至指定页', style: TextStyle(fontSize: 17)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.intro ??
                '已加载 ${widget.last} 页（第 ${widget.first}–${widget.last} 页），'
                    '只能在这些已加载的页之间跳转。\n'
                    '跳转后列表只保留目标页，其余的页向上/向下滚动即可随时补回。',
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
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _submit(),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            style: const TextStyle(fontSize: 15),
            decoration: InputDecoration(
              labelText: '页号（${widget.first}–${widget.last}）',
              prefixText: '第 ',
              suffixText: ' 页',
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('跳转'),
        ),
      ],
    );
  }
}

enum _RowKind { header, post, marker, jumpTail, footer }

class _Row {
  const _Row.pageHeader(this.page)
      : kind = _RowKind.header,
        post = null,
        index = -1;

  const _Row.post(this.post, this.index)
      : kind = _RowKind.post,
        page = 0;

  const _Row.marker()
      : kind = _RowKind.marker,
        page = 0,
        post = null,
        index = -1;

  const _Row.jumpTail()
      : kind = _RowKind.jumpTail,
        page = 0,
        post = null,
        index = -1;

  const _Row.footer()
      : kind = _RowKind.footer,
        page = 0,
        post = null,
        index = -1;

  final _RowKind kind;
  final int page;
  final Post? post;
  final int index;

  bool get isHeader => kind == _RowKind.header;
  bool get isFooter => kind == _RowKind.footer;
  bool get isMarker => kind == _RowKind.marker;
  bool get isJumpTail => kind == _RowKind.jumpTail;
}

/// 条目高度即将变化的回调。
///
/// [willShrink]：高度是否将变小（折叠整条 / 收起正文）；
/// [itemId]：发起变化的条目 id —— 列表据此判断"发起条目是否就是锚点
/// 条目"，长文中部折叠的收回定位依赖这个判断。
typedef HeightWillChange = void Function(bool willShrink, String? itemId);

/// 条目即将被删除的回调（取消收藏就地移除等场景）。
///
/// 与 [HeightWillChange] 分开是因为补偿口径不同：高度变化时锚点条目还在，
/// 删除时锚点条目本身消失，要改用"参考条目 + 预测预跳"处理（见
/// `_PagedPostListState.anchorItemRemoval`）。
typedef ItemWillBeRemoved = void Function(String itemId);

/// 把「条目高度将变 / 条目将删除，请先记下锚点」的能力透传给列表项里的卡片。
///
/// 卡片（`PostCard`）知道用户何时展开了正文/折叠了整条，但只有列表知道
/// 该锚定哪一条（视口里最靠上的那条）。用 InheritedWidget 把回调传下去，
/// 卡片不必层层接收参数，三个调用点（搜索 / 收藏 / 合集）也都不用改。
class PagedPostListAnchor extends InheritedWidget {
  const PagedPostListAnchor({
    super.key,
    required this.onHeightWillChange,
    required this.onItemWillBeRemoved,
    required super.child,
  });

  /// 在改变自身高度**之前**调用，由列表负责把滚动位置还原。
  final HeightWillChange onHeightWillChange;

  /// 在**把某条从数据里删掉之前**调用，由列表负责补偿滚动偏移。
  final ItemWillBeRemoved onItemWillBeRemoved;

  /// 取上层列表提供的回调；不在分页列表里（例如详情页）时为 null。
  ///
  /// 用 `getInheritedWidgetOfExactType` 而不是 `dependOn...`：调用点都在
  /// 手势回调里，不需要建立依赖（也不会因此让卡片跟着重建）。
  static HeightWillChange? maybeOf(BuildContext context) =>
      context
          .getInheritedWidgetOfExactType<PagedPostListAnchor>()
          ?.onHeightWillChange;

  /// 取「条目将删除」的补偿回调；不在分页列表里时为 null。
  static ItemWillBeRemoved? removalOf(BuildContext context) =>
      context
          .getInheritedWidgetOfExactType<PagedPostListAnchor>()
          ?.onItemWillBeRemoved;

  @override
  bool updateShouldNotify(PagedPostListAnchor oldWidget) =>
      oldWidget.onHeightWillChange != onHeightWillChange;
}
