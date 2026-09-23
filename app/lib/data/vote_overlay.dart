import 'dart:convert';

import '../api/models.dart';
import '../platform/native_bridge.dart';
import '../util/app_log.dart';

/// 本地点赞状态覆盖层（动态 + 评论）。
///
/// 解决的问题：点赞动作只更新内存对象与服务端，**内容缓存里的
/// `is_voted` 仍是点赞前的旧值**。下次进入「缓存续读」（或任何
/// 缓存优先的读取）把缓存原样解析出来，就会出现"实际已点赞、
/// 界面却显示未点赞"。
///
/// 机制：每次点赞/取消**成功**后，把该条的最终态按 id 记入覆盖层并
/// 落盘（SharedPreferences 键值对，量级是"我赞过多少条"，很小）。
/// 解析侧按数据来源分两种处理：
///
/// * **缓存数据**：覆盖层有记录就套用（补上缓存缺失的点赞态）——
///   这正是"再次进入缓存续读要加载最后的点赞记录"的实现；
/// * **网络数据**：做对账。服务端是最终真相，若与覆盖层冲突（例如
///   在网页端取消过赞），以服务端为准并移除覆盖层里的旧值，
///   避免覆盖层与真实状态永久分叉。
class VoteOverlay {
  VoteOverlay._();

  static final VoteOverlay instance = VoteOverlay._();

  /// SharedPreferences 键。前缀与本机自建收藏夹等键保持同一命名风格。
  ///
  /// public：数据备份导出/导入需要按同一键名读写原始 JSON。
  static const String kvKey = 'simple_vote_overlay';

  /// postId → 最终点赞态。
  final Map<String, bool> _posts = {};

  /// commentId → 最终点赞态（主楼与回复楼层同一 id 空间）。
  final Map<String, bool> _comments = {};

  bool _loaded = false;
  Future<void>? _loading;

  /// 进程内只读一次盘；后续全部走内存。
  Future<void> _ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final raw = await NativeBridge.instance.kvGet(kvKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _absorb(decoded['posts'], _posts);
          _absorb(decoded['comments'], _comments);
        }
      }
    } catch (e) {
      // 覆盖层读不出来就当没有：最坏退化为"缓存续读时点赞态照旧显示"，
      // 不影响任何主流程。
      log.w(LogTag.cache, '点赞覆盖层读取失败：$e');
    } finally {
      _loaded = true;
    }
  }

  static void _absorb(dynamic raw, Map<String, bool> into) {
    if (raw is! Map) return;
    raw.forEach((k, v) {
      final id = k.toString();
      if (id.isEmpty) return;
      into[id] = v == true || v == 1 || v.toString().toLowerCase() == 'true';
    });
  }

  Future<void> _persist() async {
    try {
      final payload = jsonEncode({'posts': _posts, 'comments': _comments});
      await NativeBridge.instance.kvSet(kvKey, payload);
    } catch (e) {
      log.w(LogTag.cache, '点赞覆盖层落盘失败：$e');
    }
  }

  // ---------------------------------------------------------------- 写入

  /// 丢弃内存态并从磁盘重载（数据导入后调用）。
  ///
  /// 覆盖层是懒加载 + 进程内缓存：导入写盘后必须显式重载，否则本次会话
  /// 仍拿旧记录对账，点赞态会与新导入的缓存内容对不上。
  Future<void> reload() async {
    _posts.clear();
    _comments.clear();
    _loaded = false;
    _loading = null;
    await _ensureLoaded();
  }

  /// 动态点赞成功后的记录（最终态，不是"点了一下"）。
  Future<void> recordPost(String postId, {required bool voted}) async {
    if (postId.isEmpty) return;
    await _ensureLoaded();
    if (_posts[postId] == voted) return;
    _posts[postId] = voted;
    await _persist();
  }

  /// 评论点赞成功后的记录（主楼与回复楼层通用）。
  Future<void> recordComment(String commentId, {required bool voted}) async {
    if (commentId.isEmpty) return;
    await _ensureLoaded();
    if (_comments[commentId] == voted) return;
    _comments[commentId] = voted;
    await _persist();
  }

  // ---------------------------------------------------------------- 同步

  /// 解析出一批动态后调用。
  ///
  /// [fromCache] 为 true（数据来自内容缓存）→ 套用覆盖层；
  /// 为 false（来自网络）→ 对账，服务端与覆盖层冲突时以服务端为准。
  Future<void> syncPosts(List<Post> posts, {required bool fromCache}) async {
    if (posts.isEmpty) return;
    await _ensureLoaded();
    if (_posts.isEmpty) return;
    var dropped = false;
    for (final p in posts) {
      final o = _posts[p.id];
      if (o == null) continue;
      if (fromCache) {
        if (p.isVoted != o) p.isVoted = o;
      } else if (p.isVoted != o) {
        // 网络真相与本地记录冲突：以服务端为准，移除旧记录。
        _posts.remove(p.id);
        dropped = true;
      }
    }
    if (dropped) await _persist();
  }

  /// 解析出一批评论后调用（含内嵌的 preview_replies 楼层）。
  Future<void> syncComments(List<Comment> comments,
      {required bool fromCache}) async {
    if (comments.isEmpty) return;
    await _ensureLoaded();
    if (_comments.isEmpty) return;
    var dropped = false;
    for (final c in comments) {
      dropped = _syncOne(c, fromCache: fromCache) || dropped;
      for (final r in c.replies) {
        dropped = _syncOne(r, fromCache: fromCache) || dropped;
      }
    }
    if (dropped) await _persist();
  }

  bool _syncOne(Comment c, {required bool fromCache}) {
    final o = _comments[c.id];
    if (o == null) return false;
    if (fromCache) {
      if (c.isVoted != o) c.isVoted = o;
    } else if (c.isVoted != o) {
      _comments.remove(c.id);
      return true;
    }
    return false;
  }
}
