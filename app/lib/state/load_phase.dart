/// 分页加载阶段。搜索与列表控制器共用。
enum LoadPhase {
  /// 尚未发起任何请求。
  idle,

  /// 正在加载第一页。
  loadingFirst,

  /// 正在加载后续页（列表已有内容，应显示底部加载条）。
  loadingMore,

  /// 加载完成。
  ready,

  /// 加载失败。
  error,
}

extension LoadPhaseX on LoadPhase {
  bool get isBusy => this == LoadPhase.loadingFirst || this == LoadPhase.loadingMore;
  bool get isFirstLoad => this == LoadPhase.loadingFirst;
}
