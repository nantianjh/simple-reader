import 'package:flutter/foundation.dart';

/// 本机数据的「重新导入」版本号 —— 导入备份后让界面整体重新取数。
///
/// 为什么需要它：数据导入是一次**整机快照覆盖**，设置、搜索历史、续读点、
/// 收藏的合集、点赞覆盖层、内容缓存全部被换掉。而这些数据的读法分两路：
///
/// * `BackupService.apply` 重载各 store —— 只会让**订阅 store 的**组件刷新
///   （设置页、合集视图这类 `AnimatedBuilder`/`ChangeNotifier` 消费方）；
/// * 搜索页与收藏页则各自在 `State` 里持有 `PagedList`／`SearchState`
///   （含已抓取的条目、游标、已读线、滚动位置）。它们既不订阅这些 store，
///   也不会因为 store 变了而重新取数 —— 于是"数据进去了、界面没换"。
///
/// 办法：导入结束后把这里 [bump] 一次，外壳按版本号给数据页换 `Key`，
/// 页面 State 整体重建 —— 内存缓存、游标、选中态一并丢弃，重新按导入后的
/// 数据取数，用户看到的就是导入后的界面。
///
/// 刻意不做成"逐页通知 + 局部失效"：那要为每个页面各写一套失效逻辑，
/// 而导入是低频重操作，重建一次的代价（一次列表请求）远低于漏刷新的风险。
class DataRevision {
  DataRevision._();

  static final DataRevision instance = DataRevision._();

  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  /// 当前版本号。
  int get value => _revision.value;

  /// 供外壳监听：值一变，数据页即重建。
  ValueListenable<int> get listenable => _revision;

  /// 通知"本机数据已被整体替换"。幂等语义无关紧要，调用方只负责在数据
  /// 真正落盘之后调用一次。
  void bump() => _revision.value++;
}
