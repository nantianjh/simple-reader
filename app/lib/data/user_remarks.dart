import 'package:flutter/foundation.dart';

import '../util/app_log.dart';
import 'local_store.dart';

/// 一条本机备注（给某个用户起的本地叫法）。
class UserRemark {
  const UserRemark({
    required this.userId,
    required this.nickname,
    required this.remark,
    required this.updatedAt,
  });

  final String userId;

  /// 记录备注时的**本名快照**。展示一律用接口给的最新昵称，这里只作为
  /// 导出文件里的可读线索（备份里只有一个用户 id 的话谁也认不出是谁）。
  final String nickname;

  /// 备注名。空串不会入库（清除即删除条目）。
  final String remark;

  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'nickname': nickname,
        'remark': remark,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  /// 从存储 / 备份里的一条记录解析。remark 为空视作无效（调用方丢弃）。
  static UserRemark? fromJson(String userId, Map<String, dynamic> m) {
    final remark = (m['remark']?.toString() ?? '').trim();
    if (userId.isEmpty || remark.isEmpty) return null;
    final at = m['updatedAt'];
    return UserRemark(
      userId: userId,
      nickname: m['nickname']?.toString() ?? '',
      remark: remark,
      updatedAt: at is num
          ? DateTime.fromMillisecondsSinceEpoch(at.toInt())
          : DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  /// 展示名拼装口径：**本名（备注名）**。任一为空时只显示另一个。
  ///
  /// 抽成纯函数是为了能被单测直接钉住 —— 这是用户唯一能感知的展示规则
  /// （2026-09-23 需求 3：备注后任何界面都显示「本名（备注名）」）。
  static String compose(String nickname, String remark) {
    final n = nickname.trim();
    final r = remark.trim();
    if (r.isEmpty) return nickname;
    if (n.isEmpty) return remark;
    return '$n（$r）';
  }
}

/// 用户备注表（本机数据，全应用一份）。
///
/// 存在 [LocalStore] 的一个键里（启动预读，UI 侧同步取用），随数据备份
/// 一起导出 / 导入（见 `BackupService` 的 `userRemarks` 类别）。
///
/// 为什么做成 [ChangeNotifier]：备注是"全局生效"的展示规则 —— 在他人主页
/// 设一次，信息流、详情页、评论区、合集作者名全都要立刻跟着变。界面侧统一
/// 用 `RemarkedText`（见 `ui/widgets/remark_name.dart`）订阅本对象，
/// 不设备注时展示的就是原来的昵称，零额外行为。
class UserRemarksStore extends ChangeNotifier {
  UserRemarksStore._();

  static final UserRemarksStore instance = UserRemarksStore._();

  final Map<String, UserRemark> _items = <String, UserRemark>{};

  bool _loaded = false;

  bool get loaded => _loaded;

  /// 备注条数（供「我的 → 高级设置」等处展示）。
  int get length => _items.length;

  /// 全部备注，按最近修改倒序（新改的在前）。
  List<UserRemark> get items {
    final list = _items.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<UserRemark>.unmodifiable(list);
  }

  /// 从本机存储读取（启动时调用；幂等，可重复调用以重载）。
  ///
  /// 读失败不影响启动：最坏退化为"没有备注"。
  Future<void> load() async {
    _items.clear();
    final raw = LocalStore.instance.readMap(LocalStore.keyUserRemarks);
    _absorb(raw);
    _loaded = true;
    notifyListeners();
  }

  void _absorb(Map<String, dynamic> raw) {
    final items = raw['items'];
    if (items is! Map) return;
    items.forEach((k, v) {
      if (v is! Map) return;
      final entry = UserRemark.fromJson(
        k.toString(),
        v.map((key, value) => MapEntry(key.toString(), value)),
      );
      if (entry != null) _items[entry.userId] = entry;
    });
  }

  /// 取得某人的备注名。没设备注返回 null。
  String? remarkOf(String userId) {
    if (userId.isEmpty) return null;
    final r = _items[userId]?.remark;
    return (r == null || r.isEmpty) ? null : r;
  }

  /// 该用户是否已设备注。
  bool has(String userId) => remarkOf(userId) != null;

  /// 展示名：设备注 → 「本名（备注名）」，否则原样返回本名。
  ///
  /// [nickname] 用调用处手上的最新昵称（列表/详情/评论各自的数据），
  /// 这样对方改名后展示跟着变，备注始终生效。
  String display(String nickname, String userId) =>
      UserRemark.compose(nickname, remarkOf(userId) ?? '');

  /// 设置 / 修改备注。[remark] 传空串即**清除**备注。
  ///
  /// [nickname] 传当前本名，作为导出文件里的可读线索。
  Future<void> setRemark({
    required String userId,
    required String nickname,
    required String remark,
  }) async {
    if (userId.isEmpty) return;
    final value = remark.trim();
    final before = remarkOf(userId);
    if (value.isEmpty) {
      if (before == null) return;
      _items.remove(userId);
    } else {
      _items[userId] = UserRemark(
        userId: userId,
        nickname: nickname.trim(),
        remark: value,
        updatedAt: DateTime.now(),
      );
    }
    notifyListeners();
    await _persist();
    log.i(
      LogTag.ui,
      value.isEmpty
          ? '已清除备注：$userId'
          : '已设置备注：$userId（$nickname → $value）',
    );
  }

  /// 清除备注（等价于 [setRemark] 传空备注）。
  Future<void> clear(String userId) =>
      setRemark(userId: userId, nickname: '', remark: '');

  /// 导出 / 导入用的结构：`{ "items": { "<userId>": { nickname, remark, updatedAt } } }`。
  Map<String, dynamic> toJson() => {
        'items': <String, dynamic>{
          for (final e in _items.entries) e.key: e.value.toJson(),
        },
      };

  /// 用备份里的内容**整体替换**（导入语义：快照覆盖）。
  Future<void> replaceAll(Map<String, dynamic> raw) async {
    await LocalStore.instance.write(LocalStore.keyUserRemarks, {
      'items': raw['items'] is Map ? raw['items'] : <String, dynamic>{},
    });
    await load();
  }

  Future<void> _persist() async {
    try {
      await LocalStore.instance.write(LocalStore.keyUserRemarks, toJson());
    } catch (e) {
      // 落盘失败不回滚内存态：本次会话里备注照常生效，只是重启后丢失。
      log.w(LogTag.ui, '备注落盘失败：$e');
    }
  }
}
