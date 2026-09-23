import 'dart:async';

import 'package:flutter/widgets.dart';

/// 列表项「完整显示」跟踪器。
///
/// 需求语义：某一条动态的分隔框完整显示在可视区域内，即视为已读。
/// 实现方式是给每个列表项挂一个 [GlobalKey]，在滚动结束后遍历这些项，
/// 求出「最后一个上下边界都完整落在列表视口内」的那一条。
///
/// key 由调用方决定用什么做标识 —— 分页式列表里用内容 id 而不是行号，
/// 因为向上补页会让所有行号整体后移，用 id 才能保持稳定。
///
/// 只依赖渲染树坐标，不需要第三方可见性插件。
class ItemVisibilityTracker {
  ItemVisibilityTracker(this.scrollController);

  final ScrollController scrollController;

  final Map<Object, GlobalKey> _keys = <Object, GlobalKey>{};

  /// 取得（或创建）某个标识对应的 key，供 `KeyedSubtree` 使用。
  GlobalKey keyFor(Object id) =>
      _keys.putIfAbsent(id, () => GlobalKey(debugLabel: 'item:$id'));

  void reset() => _keys.clear();

  /// 列表自身（滚动容器）的 RenderBox，用于确定"视口"范围。
  RenderBox? get _listBox {
    if (!scrollController.hasClients) return null;
    final ctx = scrollController.position.context.storageContext;
    final ro = ctx.findRenderObject();
    if (ro is RenderBox && ro.attached && ro.hasSize) return ro;
    return null;
  }

  /// 最后一个「完整可见」的标识；没有任何项完整可见时返回 null。
  ///
  /// [ids] 按列表顺序给出当前所有条目的标识。
  Object? lastFullyVisibleKey(List<Object> ids) {
    if (ids.isEmpty) return null;
    final listBox = _listBox;
    if (listBox == null) return null;

    final listTop = listBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = listTop + listBox.size.height;

    Object? last;
    for (final id in ids) {
      final box = _boxOf(id);
      if (box == null) continue; // 未渲染（在 cacheExtent 之外）

      final itemTop = box.localToGlobal(Offset.zero).dy;
      final itemBottom = itemTop + box.size.height;

      // 容 1px 误差，规避浮点取整导致的"差一点点不算完整"。
      if (itemTop >= listTop - 1 && itemBottom <= viewportBottom + 1) {
        last = id;
      }
    }
    return last;
  }

  /// 视口里**最靠上**的已渲染标识（允许只露出一部分）。
  ///
  /// 用于「条目高度变化后重新锚定」：只要求它在视口内可见，不要求完整可见
  /// （长卡片常常只露出上半部分）。锚点取最上面那一条，视觉上最稳定 ——
  /// 用户是从上往下读的，上沿不动就不会有"画面被抽走"的观感。
  Object? firstVisibleKey(List<Object> ids) {
    if (ids.isEmpty) return null;
    final listBox = _listBox;
    if (listBox == null) return null;

    final listTop = listBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = listTop + listBox.size.height;

    for (final id in ids) {
      final box = _boxOf(id);
      if (box == null) continue; // 未渲染（在 cacheExtent 之外）
      final itemTop = box.localToGlobal(Offset.zero).dy;
      final itemBottom = itemTop + box.size.height;
      if (itemBottom > listTop + 1 && itemTop < viewportBottom - 1) return id;
    }
    return null;
  }

  /// 某条在滚动内容坐标系里的偏移；尚未渲染时返回 null。
  double? offsetOfKey(Object id) {
    final listBox = _listBox;
    if (listBox == null) return null;
    final box = _boxOf(id);
    if (box == null) return null;
    final relative = box.localToGlobal(Offset.zero, ancestor: listBox).dy;
    return scrollController.offset + relative;
  }

  /// 某条相对视口顶部的偏移（负值表示已在视口上方）；未渲染时返回 null。
  double? viewportTopOfKey(Object id) {
    final listBox = _listBox;
    if (listBox == null) return null;
    final box = _boxOf(id);
    if (box == null) return null;
    final itemTop = box.localToGlobal(Offset.zero).dy;
    final listTop = listBox.localToGlobal(Offset.zero).dy;
    return itemTop - listTop;
  }

  RenderBox? _boxOf(Object id) {
    final ctx = _keys[id]?.currentContext;
    if (ctx == null) return null;
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
    return ro;
  }
}

/// 把列表滚到指定的条目上（该项需已在列表里；未渲染时逐步向下推进）。
///
/// 分页式列表里目标条目可能在本页靠后的位置，而 `ListView` 是懒构建的，
/// 只有进入 cacheExtent 的行才有 RenderObject，因此分几步走、每步等一帧。
Future<bool> scrollToTrackedItem({
  required ScrollController scroll,
  required ItemVisibilityTracker tracker,
  required Object id,
  int maxSteps = 24,
}) async {
  if (!scroll.hasClients) return false;

  for (var attempt = 0; attempt < maxSteps; attempt++) {
    final offset = tracker.offsetOfKey(id);
    if (offset != null) {
      scroll.jumpTo(offset.clamp(0.0, scroll.position.maxScrollExtent));
      return true;
    }
    final next = (scroll.offset + scroll.position.viewportDimension * 0.7)
        .clamp(0.0, scroll.position.maxScrollExtent);
    if (next <= scroll.offset + 1) return false; // 到底了
    scroll.jumpTo(next);
    await _nextFrame();
  }
  return false;
}

/// 等一帧结束。加超时兜底，避免在没有排帧的环境里把流程挂死。
Future<void> _nextFrame() async {
  try {
    await WidgetsBinding.instance.endOfFrame
        .timeout(const Duration(milliseconds: 500));
  } on TimeoutException {
    // 忽略：继续下一步，最差情况是这一次滚动没生效。
  }
}

/// 等布局完成，供"补页后校正滚动偏移"使用。
Future<void> settleFrame() => _nextFrame();
