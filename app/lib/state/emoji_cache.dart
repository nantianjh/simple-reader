import 'dart:async';

import '../api/models.dart';
import '../api/simple_api.dart';
import '../data/local_store.dart';
import '../util/app_log.dart';

/// 表情面板的全局缓存（v1.9.2）。
///
/// 背景：表情面板是按需挂载的组件——详情页评论栏、动态卡片的内联评论
/// 条都可能各挂一份，此前没有任何跨实例缓存，每打开一次都重拉「包列表 +
/// 收藏 + 当前包内容」，表现为"每次点开都要加载一圈"。
///
/// 三层结构：
/// * **内存常驻**：本进程内所有面板实例共享，命中即渲染（0 请求）；
/// * **磁盘快照**：经 [LocalStore] 存 JSON（启动时预读），冷启动首次
///   打开也能秒出，之后按 TTL 后台刷新；
/// * **TTL 刷新**：距上次成功拉取超过 [ttl] 时重拉一次——旧数据先顶着
///   渲染，刷新失败保留旧数据（表情包与收藏都是低频数据，只在官方端
///   变化，宁可短暂陈旧也不让面板转圈）。
///
/// 「收藏」tab 是账号级数据：快照带 token 指纹，换号登录后自动丢弃。
/// 指纹只取 token 首尾片段，不在缓存里落完整凭证（token 本体由
/// TokenStore 单独管理）。
class EmojiCache {
  EmojiCache._();

  static final EmojiCache instance = EmojiCache._();

  static const String _storeKey = LocalStore.keyEmojiCache;

  /// 刷新间隔。
  static const Duration ttl = Duration(hours: 24);

  final SimpleApi _api = SimpleApi();

  /// 包列表。null = 尚未加载（内存与磁盘都没有）。
  List<EmojiPackage>? packages;

  /// 各 tab 内容：key = 'fav'（收藏）或包 id。
  final Map<String, List<Emoji>> _contents = {};

  DateTime? _fetchedAt;
  String? _tokenFingerprint;

  /// 进行中的整体加载（多个面板同时打开合并为一次请求）。
  Future<void>? _baseJob;

  /// 进行中的单包加载。
  final Map<String, Future<void>> _contentJobs = {};

  /// 读取某个 tab 的内容；没有返回 null（调用方再走 [ensureContent]）。
  List<Emoji>? contentOf(String key) => _contents[key];

  /// 缓存是否存在且在 TTL 内。
  bool get isFresh =>
      _fetchedAt != null && DateTime.now().difference(_fetchedAt!) < ttl;

  /// 确保包列表与整体缓存可用：内存 → 磁盘 → 网络，逐层回落。
  ///
  /// 返回包列表；失败抛异常（面板据此展示"点击重试"，但已渲染的旧数据
  /// 不收回）。
  Future<List<EmojiPackage>> ensureBase({required String token}) async {
    if (packages != null && isFresh) return packages!;
    final existing = _baseJob;
    if (existing != null) {
      await existing;
      return packages ?? (throw Exception('表情加载失败'));
    }
    final job = _loadBase(token);
    _baseJob = job;
    try {
      await job;
      return packages!;
    } finally {
      if (identical(_baseJob, job)) _baseJob = null;
    }
  }

  Future<void> _loadBase(String token) async {
    final fp = _fingerprint(token);
    // 换号：收藏是账号级数据，指纹不一致直接丢旧缓存。
    if (_tokenFingerprint != null && _tokenFingerprint != fp) {
      _discardMemory();
    }
    _tokenFingerprint = fp;

    if (packages == null) await _restoreFromDisk(fp);

    if (packages != null && isFresh) return;

    // 串行请求（与工程其余网络调用同口径，不做并发）。
    final pkgs = await _api.fetchEmojiPackages(token: token);
    final fav = await _api.fetchEmojiFavorites(token: token);
    packages = pkgs;
    _contents['fav'] = fav;
    _fetchedAt = DateTime.now();
    await _persist();
    log.i(LogTag.net, '表情缓存已刷新（${pkgs.length} 个包）');
  }

  /// 确保某个 tab 的内容可用（'fav' 或包 id），返回内容列表。
  Future<List<Emoji>> ensureContent(String key, {required String token}) async {
    final cached = _contents[key];
    if (cached != null && isFresh) return cached;
    final existing = _contentJobs[key];
    if (existing != null) {
      await existing;
      return _contents[key] ?? (throw Exception('表情加载失败'));
    }
    final job = _loadContent(key, token);
    _contentJobs[key] = job;
    try {
      await job;
      return _contents[key] ?? (throw Exception('表情加载失败'));
    } finally {
      if (identical(_contentJobs[key], job)) _contentJobs.remove(key);
    }
  }

  Future<void> _loadContent(String key, String token) async {
    if (_contents.containsKey(key) && isFresh) return;
    final emojis = key == 'fav'
        ? await _api.fetchEmojiFavorites(token: token)
        : await _api.fetchEmojis(token: token, packageEmojiId: key);
    _contents[key] = emojis;
    await _persist();
  }

  // ---------------------------------------------------------------- 落盘

  Future<void> _restoreFromDisk(String fp) async {
    try {
      final raw = LocalStore.instance.readMap(_storeKey);
      if (raw.isEmpty) return;
      if (raw['fp'] != fp) return; // 换过账号：丢弃旧快照
      final fetchedAt = raw['fetchedAt'];
      final pkgsRaw = raw['packages'];
      if (fetchedAt is! int || pkgsRaw is! List) return;
      final pkgs = <EmojiPackage>[
        for (final p in pkgsRaw)
          if (p is Map)
            EmojiPackage.fromJson(p.map((k, v) => MapEntry(k.toString(), v))),
      ];
      if (pkgs.isEmpty) return;
      packages = pkgs;
      _fetchedAt = DateTime.fromMillisecondsSinceEpoch(fetchedAt);
      _tokenFingerprint = fp;
      final contentsRaw = raw['contents'];
      if (contentsRaw is Map) {
        for (final entry in contentsRaw.entries) {
          final list = entry.value;
          if (list is! List) continue;
          _contents[entry.key.toString()] = <Emoji>[
            for (final e in list)
              if (e is Map)
                Emoji.fromJson(e.map((k, v) => MapEntry(k.toString(), v))),
          ];
        }
      }
      log.d(LogTag.net, '表情缓存已从磁盘恢复（${pkgs.length} 个包）');
    } catch (e) {
      // 快照损坏只影响"秒开"，下次拉取会覆盖，不当作错误上抛。
      log.w(LogTag.net, '表情缓存磁盘快照损坏，忽略：$e');
    }
  }

  Future<void> _persist() async {
    if (packages == null || _fetchedAt == null || _tokenFingerprint == null) {
      return;
    }
    await LocalStore.instance.write(_storeKey, {
      'fp': _tokenFingerprint,
      'fetchedAt': _fetchedAt!.millisecondsSinceEpoch,
      'packages': [
        for (final p in packages!) {'id': p.id, 'name': p.name, 'icon': p.icon},
      ],
      'contents': {
        for (final e in _contents.entries)
          e.key: [
            for (final em in e.value) {'id': em.id, 'url': em.url},
          ],
      },
    });
  }

  void _discardMemory() {
    packages = null;
    _contents.clear();
    _fetchedAt = null;
    _tokenFingerprint = null;
  }

  /// token 指纹：首尾各 8 字符。只做"是否同一个号"的比对，
  /// 不承载任何凭证语义。
  static String _fingerprint(String token) {
    if (token.length < 20) return token;
    return '${token.substring(0, 8)}…${token.substring(token.length - 8)}';
  }
}
