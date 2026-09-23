import 'dart:convert';

import '../platform/native_bridge.dart';

/// 轻量本地配置存储。
///
/// 启动时一次性把已知的几个键读进内存，之后 UI 层全部同步访问，
/// 不必到处 `await`；写入异步落盘，不阻塞交互。
///
/// 之所以集中成几个「大对象」而不是每项一个键，是为了：
/// * 启动时几次通道调用即可完成全部预读（见 [_preloadedKeys] 的条数）；
/// * 动态增生的数据（续读点按 scope 增长）不需要逐一预读。
class LocalStore {
  LocalStore._();

  static final LocalStore instance = LocalStore._();

  /// 应用设置。
  static const String keySettings = 'simple_settings';

  /// 搜索历史（字符串数组）。
  static const String keySearchHistory = 'simple_search_history';

  /// 阅读续读点（scope -> 位置对象）。
  static const String keyReadPositions = 'simple_read_positions';

  /// 本机自建的「收藏的合集」（条目表 + 本机删除墓碑）。
  static const String keyFavCollections = 'simple_fav_collections';

  /// 表情面板全局缓存（包列表 + 各包/收藏内容，带 token 指纹与拉取时间）。
  static const String keyEmojiCache = 'simple_emoji_cache_v1';

  /// 用户备注（userId → { nickname, remark, updatedAt }）。
  ///
  /// 放这里而不是单独一个懒加载文件：备注是**展示时同步读取**的全局规则
  /// （信息流每张卡片都要取一次），启动预读进内存最省事。
  static const String keyUserRemarks = 'simple_user_remarks';

  /// 上次展示过「更新内容」的版本号（纯字符串）。
  ///
  /// 刻意单独放一个键、不塞进设置：它是**本机**的阅读记账，跟着设备走；
  /// 塞进设置里会被"导入备份"连带覆盖成别的设备的值，导致更新提示重复弹
  /// 或该弹不弹。也不进备份文件 —— 换机后首次启动本来就该看到这次的变化。
  static const String keyLastSeenVersion = 'simple_last_seen_version';

  static const List<String> _preloadedKeys = [
    keySettings,
    keySearchHistory,
    keyReadPositions,
    keyFavCollections,
    keyEmojiCache,
    keyLastSeenVersion,
    keyUserRemarks,
  ];

  final Map<String, dynamic> _memory = {};

  bool get loaded => _loaded;
  bool _loaded = false;

  /// 启动时预读。任何键读失败或 JSON 损坏都只影响该项，不阻断启动。
  Future<void> loadAll() async {
    for (final key in _preloadedKeys) {
      final raw = await NativeBridge.instance.kvGet(key);
      if (raw == null || raw.trim().isEmpty) continue;
      try {
        _memory[key] = jsonDecode(raw);
      } catch (_) {
        // 数据损坏时丢弃该项，下次写入会覆盖。
      }
    }
    _loaded = true;
  }

  /// 读取一个对象型配置。缺失或类型不符时返回空 Map。
  Map<String, dynamic> readMap(String key) {
    final v = _memory[key];
    if (v is Map) {
      return v.map((k, value) => MapEntry(k.toString(), value));
    }
    return <String, dynamic>{};
  }

  /// 读取一个数组型配置。缺失或类型不符时返回空列表。
  List<dynamic> readList(String key) {
    final v = _memory[key];
    if (v is List) return v;
    return const [];
  }

  /// 读取一个字符串型配置（如「上次看过的版本号」）。缺失或类型不符返回 null。
  String? readString(String key) {
    final v = _memory[key];
    if (v is String && v.isNotEmpty) return v;
    return null;
  }

  Future<void> write(String key, Object? value) async {
    _memory[key] = value;
    await NativeBridge.instance.kvSet(key, jsonEncode(value));
  }

  Future<void> remove(String key) async {
    _memory.remove(key);
    await NativeBridge.instance.kvRemove(key);
  }
}
