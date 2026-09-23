import 'dart:async';
import 'dart:convert';

import '../platform/native_bridge.dart';
import '../util/app_log.dart';
import 'settings.dart';

/// 一次缓存命中。
class CachedRows {
  const CachedRows({required this.rows, required this.savedAt});

  final List<Map<String, dynamic>> rows;
  final DateTime savedAt;
}

/// 已抓取内容的本地缓存。
///
/// 设计要点：
/// * 以「请求签名」为键，签名包含版本 / 接口 / 关键词 / 游标 / 每页条数，
///   任一变化都会落到不同的缓存文件；
/// * 落盘为文件而不是 SharedPreferences —— 单页内容可达数十 KB，
///   键值存储不适合承载；
/// * 文件内同时写入签名，读取时二次校验，即使哈希碰撞也不会串数据；
/// * 保留期限由 [AppSettings.retentionDays] 决定，0 表示完全不缓存。
class ContentCache {
  ContentCache._();

  static final ContentCache instance = ContentCache._();

  static const String _filePrefix = 'c_';
  static const int _msPerDay = 24 * 60 * 60 * 1000;

  /// 读取缓存。未命中、已过期或数据损坏时返回 null。
  ///
  /// [ignoreExpiry] 为 true 时忽略保留期限——用于网络失败后的兜底读取。
  Future<CachedRows?> read(String signature, {bool ignoreExpiry = false}) async {
    if (signature.isEmpty) return null;
    if (!ignoreExpiry && !AppSettings.instance.retention.enabled) {
      log.d(LogTag.cache, '未命中（保留期已关闭）：$signature');
      return null;
    }

    final raw = await NativeBridge.instance.fileRead(fileNameFor(signature));
    if (raw == null || raw.isEmpty) {
      log.d(LogTag.cache, '未命中（无文件）：$signature');
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final m = decoded.map((k, v) => MapEntry(k.toString(), v));

      // 二次校验签名，防止哈希碰撞导致的错配。
      if (m['sig']?.toString() != signature) {
        log.w(LogTag.cache, '签名不匹配，按未命中处理：$signature');
        return null;
      }

      final savedAtRaw = m['savedAt'];
      final savedAt = savedAtRaw is num
          ? DateTime.fromMillisecondsSinceEpoch(savedAtRaw.toInt())
          : DateTime.now();

      if (!ignoreExpiry && _isExpired(savedAt)) {
        log.d(LogTag.cache, '未命中（已过期）：$signature');
        return null;
      }

      final rowsRaw = m['rows'];
      if (rowsRaw is! List) return null;

      final rows = <Map<String, dynamic>>[];
      for (final e in rowsRaw) {
        if (e is Map) {
          rows.add(e.map((k, v) => MapEntry(k.toString(), v)));
        }
      }
      log.d(
        LogTag.cache,
        '命中${ignoreExpiry ? '（忽略保留期）' : ''}：${rows.length} 条｜$signature',
      );
      return CachedRows(rows: rows, savedAt: savedAt);
    } catch (e) {
      // 文件损坏：删除后按未命中处理。
      log.w(LogTag.cache, '缓存文件损坏，已删除：$signature｜$e');
      unawaited(NativeBridge.instance.fileDelete(fileNameFor(signature)));
      return null;
    }
  }

  /// 写入缓存。返回是否真的落盘（保留期关闭时不写）。
  Future<bool> write(
    String signature,
    List<Map<String, dynamic>> rows,
  ) async {
    if (signature.isEmpty || rows.isEmpty) return false;
    if (!AppSettings.instance.retention.enabled) {
      log.d(LogTag.cache, '跳过落盘（保留期已关闭）：$signature');
      return false;
    }

    final payload = jsonEncode({
      'sig': signature,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'rows': rows,
    });
    final ok = await NativeBridge.instance.fileWrite(fileNameFor(signature), payload);
    log.d(
      LogTag.cache,
      '${ok ? '落盘' : '落盘失败'}：${rows.length} 条 / ${payload.length} B｜$signature',
    );
    return ok;
  }

  /// 按当前保留期限清理过期缓存，返回删除的文件数。
  Future<int> purgeExpired() async {
    final days = AppSettings.instance.retentionDays;
    if (!AppSettings.instance.retention.enabled) {
      final n = await clearAll();
      log.i(LogTag.cache, '保留期已关闭，清空全部缓存：$n 项');
      return n;
    }
    if (days < 0) return 0; // 永久保留
    final n = await NativeBridge.instance.filePurge(days);
    log.i(LogTag.cache, '清理超过 $days 天的缓存：$n 项');
    return n;
  }

  /// 清空全部缓存。
  Future<int> clearAll() => NativeBridge.instance.fileClear();

  Future<StorageStats> stats() => NativeBridge.instance.fileStats();

  bool _isExpired(DateTime savedAt) {
    final days = AppSettings.instance.retentionDays;
    if (days < 0) return false; // 永久
    if (days == 0) return true; // 不缓存
    return DateTime.now().difference(savedAt).inMilliseconds > days * _msPerDay;
  }

  /// 文件名：固定前缀 + 签名哈希。签名本身存在文件内容里。
  ///
  /// public static：导入备份时要按同一算法还原文件名，不能各写一套。
  static String fileNameFor(String signature) =>
      '$_filePrefix${_fnv1a(signature)}.json';

  /// 32 位 FNV-1a。手写是为了不引入 `crypto` 依赖——
  /// 这里只需要「稳定、短、低碰撞」，不需要密码学强度。
  static String _fnv1a(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }
}

/// 缓存作用域的签名生成统一入口，避免各处手写拼接规则。
class CacheKey {
  CacheKey._();

  static String search({
    required String path,
    required String keyword,
    required String lastId,
    required int perPage,
  }) =>
      'v3|$path|$keyword|$lastId|$perPage';

  /// 收藏夹。签名里带上具体接口与数据源，探测期间不同候选不会互相覆盖。
  static String favourites({
    required String path,
    required String? source,
    required String lastId,
    required int perPage,
  }) =>
      'v2|$path|${source ?? ''}|$lastId|$perPage';

  /// 合集内动态。
  ///
  /// 签名里带上端点（`posts/profile` 与 `posts/mine`）与作者 —— 同一个合集 id
  /// 配不同作者会打到不同结果，不能互相覆盖。
  static String collectionPosts({
    required String path,
    required String authorId,
    required String collectionId,
    required String lastId,
    required int perPage,
  }) =>
      'v2|$path|$authorId|$collectionId|$lastId|$perPage';

  static String comments({
    required String postId,
    required String lastId,
    required int perPage,
  }) =>
      'v2|comments|$postId|$lastId|$perPage';

  /// 某条评论的回复列表（GET api/v2/comments/replies）。
  ///
  /// 与评论列表同族但端点不同，签名前缀区分开，避免互相覆盖。
  static String commentReplies({
    required String commentId,
    required String lastId,
    required int perPage,
  }) =>
      'v2|comments/replies|$commentId|$lastId|$perPage';

  /// 他人主页的动态流（GET api/v2/posts/profile?user_id=，不带合集参数）。
  ///
  /// 签名以 `user` 起头，与合集内容的 `v2|posts/profile|<作者>|<合集>` 区分
  /// ——合集内容的 authorId 是 uuid，'user' 不是合法 uuid，不会撞键。
  static String userPosts({
    required String userId,
    required String lastId,
    required int perPage,
  }) =>
      'v2|posts/profile|user|$userId|$lastId|$perPage';
}
