import 'dart:convert';

import '../app_info.dart';
import '../platform/native_bridge.dart';
import '../util/app_log.dart';
import 'content_cache.dart';
import 'data_revision.dart';
import 'favourite_collections.dart';
import 'local_store.dart';
import 'reading_positions.dart';
import 'search_history.dart';
import 'settings.dart';
import 'user_remarks.dart';
import 'vote_overlay.dart';

/// 一条内容缓存（备份里的最小单元）。
class BackupCacheEntry {
  const BackupCacheEntry({
    required this.signature,
    required this.savedAt,
    required this.rows,
  });

  /// 请求签名：`v3|<路径>|<关键词>|<游标>|<每页条数>` 这类平台无关的串。
  final String signature;

  /// 抓取时间（epoch 毫秒）。
  final int savedAt;

  /// 该页解析出的原始动态 JSON。
  final List<Map<String, dynamic>> rows;
}

/// 备份文件解析结果。
///
/// 只做解析与承载，不碰磁盘 —— 导入前的确认弹窗与真正执行导入共用它。
class BackupPayload {
  const BackupPayload({
    required this.schema,
    required this.platform,
    required this.appVersion,
    required this.exportedAt,
    required this.provided,
    required this.settings,
    required this.searchHistory,
    required this.readPositions,
    required this.favouriteCollections,
    required this.voteOverlay,
    required this.userRemarks,
    required this.contentCache,
  });

  final int schema;
  final String platform;
  final String appVersion;
  final DateTime exportedAt;

  /// 文件里**真实出现过**的 data 字段名（取自 `data` 的键）。
  ///
  /// 有了它才分得清"这一类数据是空"与"这一类数据文件里根本没有"：
  /// 完整备份（导出的文件）七个字段都在 → 覆盖式还原；
  /// 手写的局部文件（例如只想导入搜索词的范本）只带一个字段 →
  /// 其余类别一律不碰本机数据。判据是**字段是否存在**，不是值是否为空。
  final Set<String> provided;

  final Map<String, dynamic> settings;
  final List<String> searchHistory;
  final Map<String, dynamic> readPositions;
  final Map<String, dynamic> favouriteCollections;
  final Map<String, dynamic> voteOverlay;

  /// 用户备注（userId → { nickname, remark, updatedAt }）。
  final Map<String, dynamic> userRemarks;

  final List<BackupCacheEntry> contentCache;

  /// 文件是否覆盖全部数据类别（即"整机快照"，导出的文件都是这种）。
  bool get isFullSnapshot =>
      BackupService.knownSections.every(provided.contains);

  /// 本次备份包含的合集条数（供确认弹窗展示）。
  int get collectionCount {
    final items = favouriteCollections['items'];
    return items is Map ? items.length : 0;
  }

  /// 本次备份包含的用户备注条数（供确认弹窗展示）。
  int get remarkCount {
    final items = userRemarks['items'];
    return items is Map ? items.length : 0;
  }

  int get cacheEntryCount => contentCache.length;
  int get historyCount => searchHistory.length;
  int get readPositionCount => readPositions.length;

  /// 文件携带的数据类别中文名（顺序固定，供确认弹窗逐条列出）。
  List<String> get includedLabels => [
        for (final e in BackupService.sectionLabels.entries)
          if (provided.contains(e.key)) e.value,
      ];
}

/// 导入结果统计。
class BackupImportSummary {
  const BackupImportSummary({
    required this.cacheEntries,
    required this.collections,
    required this.historyItems,
    required this.readPositions,
    required this.remarks,
  });

  final int cacheEntries;
  final int collections;
  final int historyItems;
  final int readPositions;

  /// 恢复的用户备注条数。
  final int remarks;
}

/// 本机数据的备份与恢复。
///
/// 目的有两层：
/// 1. **迁移** —— 换机、或换包名版本（v1.9.0 的 `simple_search` →
///    `simple_reader`，两个包名在系统里是两个应用，本机数据不共享）时
///    把数据整体搬过去；
/// 2. **跨端互通预留** —— 备份是纯 JSON，字段语义与平台无关（时间统一
///    epoch 毫秒、缓存以「请求签名」为键），将来的网页版只要实现同一份
///    schema 就能与安卓端互换。
///
/// 结构（`schema = 1`）：
/// ```json
/// {
///   "schema": 1,
///   "app": "simple-reader",
///   "platform": "android",
///   "appVersion": "1.9.1",
///   "exportedAt": 1758200000000,
///   "data": {
///     "settings": { ... },
///     "searchHistory": [ "关键词" ],
///     "readPositions": { "<scope>": { ... } },
///     "favouriteCollections": { "items": { ... }, "removed": [ ... ] },
///     "voteOverlay": { "posts": { "<postId>": "comfort" }, "comments": { "<commentId>": true } },
///     "userRemarks": { "items": { "<userId>": { "nickname": "本名", "remark": "备注名", "updatedAt": 0 } } },
///     "contentCache": [ { "sig": "...", "savedAt": 0, "rows": [ ... ] } ]
///   }
/// }
/// ```
///
/// **不含访问凭证**：token 是本机私有凭证，不写进任何可导出文件（与本工程
/// 「凭证不外传」的约定一致）；换端后重新登录即可。
///
/// `voteOverlay.posts` 的值是**表态 id**（`"unknown"` = 普通赞；可送出的那
/// 几种见 `vote_states.dart`），评论侧仍是 bool。1.9.6 及以前动态侧存的是
/// `true`/`false`，旧备份/旧落盘数据照样读得进来（见 `VoteOverlay`）。
///
/// **局部导入（2026-09-22）**：判据是 `data` 里**字段存不存在**，不是值空不空 ——
/// 导出的备份七个字段齐全 ⇒ 语义仍是"整机快照覆盖"；手写的局部文件（例如
/// 只带 `searchHistory` 的搜索词范本）⇒ 只写它带的类别，其余类别不动本机数据。
/// 这样"只想批量导入一批搜索词"就不必先把设置、合集、续读点一起端上来。
class BackupService {
  BackupService._();

  /// schema 版本。字段一旦增删必须递增，导入端据此判断能否识别。
  static const int schema = 1;

  /// 全部数据类别（`data` 下的键）。顺序即确认弹窗的展示顺序。
  static const Map<String, String> sectionLabels = {
    'settings': '设置',
    'searchHistory': '搜索历史',
    'readPositions': '阅读存档（续读点）',
    'favouriteCollections': '收藏的合集',
    'voteOverlay': '点赞记录',
    'userRemarks': '用户备注',
    'contentCache': '已缓存内容',
  };

  /// 全部数据类别的键集合。
  static Set<String> get knownSections => sectionLabels.keys.toSet();

  /// 文件名：`Simple阅读备份-20260918-231500.json`。
  static String defaultFileName() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${AppInfo.backupFilePrefix}-'
        '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.json';
  }

  /// 组装备份文本（紧凑 JSON，体积优先）。
  ///
  /// 缓存条目逐文件读取；读不出来的（损坏、格式漂移）直接跳过，
  /// 不让一条坏数据毁掉整份备份。
  static Future<String> exportText() async {
    final store = LocalStore.instance;

    var vote = <String, dynamic>{};
    final voteRaw = await NativeBridge.instance.kvGet(VoteOverlay.kvKey);
    if (voteRaw != null && voteRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(voteRaw);
        if (decoded is Map) {
          vote = decoded.map((k, v) => MapEntry(k.toString(), v));
        }
      } catch (e) {
        log.w(LogTag.cache, '备份：点赞覆盖层解析失败，已跳过｜$e');
      }
    }

    final cache = <Map<String, dynamic>>[];
    var skipped = 0;
    for (final name in await NativeBridge.instance.fileList()) {
      final raw = await NativeBridge.instance.fileRead(name);
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          skipped++;
          continue;
        }
        final m = decoded.map((k, v) => MapEntry(k.toString(), v));
        final sig = m['sig']?.toString() ?? '';
        final rows = m['rows'];
        if (sig.isEmpty || rows is! List) {
          skipped++;
          continue;
        }
        cache.add({
          'sig': sig,
          'savedAt': m['savedAt'] is num ? m['savedAt'] : 0,
          'rows': rows,
        });
      } catch (_) {
        skipped++;
      }
    }

    final payload = <String, dynamic>{
      'schema': schema,
      'app': AppInfo.appId,
      'platform': 'android',
      'appVersion': AppInfo.version,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      'data': <String, dynamic>{
        'settings': store.readMap(LocalStore.keySettings),
        'searchHistory': store.readList(LocalStore.keySearchHistory),
        'readPositions': store.readMap(LocalStore.keyReadPositions),
        'favouriteCollections': store.readMap(LocalStore.keyFavCollections),
        'voteOverlay': vote,
        'userRemarks': store.readMap(LocalStore.keyUserRemarks),
        'contentCache': cache,
      },
    };

    final text = jsonEncode(payload);
    log.i(
      LogTag.cache,
      '备份已组装：缓存 ${cache.length} 条（跳过 $skipped）、'
      '合集 ${_countCollections(store.readMap(LocalStore.keyFavCollections))} 个、'
      '历史 ${store.readList(LocalStore.keySearchHistory).length} 条、'
      '备注 ${UserRemarksStore.instance.length} 条、'
      '${text.length} B',
    );
    return text;
  }

  /// 解析备份文本。无法识别（不是本应用的备份、schema 更新、结构破损）时返回 null。
  static BackupPayload? parse(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final m = decoded.map((k, v) => MapEntry(k.toString(), v));

      if (m['app']?.toString() != AppInfo.appId) return null;
      final rawSchema = m['schema'];
      if (rawSchema is! num || rawSchema.toInt() > schema) return null;

      final data = m['data'];
      if (data is! Map) return null;
      final d = data.map((k, v) => MapEntry(k.toString(), v));

      final cache = <BackupCacheEntry>[];
      final rawCache = d['contentCache'];
      if (rawCache is List) {
        for (final e in rawCache) {
          if (e is! Map) continue;
          final em = e.map((k, v) => MapEntry(k.toString(), v));
          final sig = em['sig']?.toString() ?? '';
          final rowsRaw = em['rows'];
          if (sig.isEmpty || rowsRaw is! List) continue;
          final rows = <Map<String, dynamic>>[];
          for (final r in rowsRaw) {
            if (r is Map) {
              rows.add(r.map((k, v) => MapEntry(k.toString(), v)));
            }
          }
          cache.add(BackupCacheEntry(
            signature: sig,
            savedAt: em['savedAt'] is num ? (em['savedAt'] as num).toInt() : 0,
            rows: rows,
          ));
        }
      }

      final exportedAtRaw = m['exportedAt'];
      return BackupPayload(
        schema: rawSchema.toInt(),
        platform: m['platform']?.toString() ?? '',
        appVersion: m['appVersion']?.toString() ?? '',
        exportedAt: exportedAtRaw is num
            ? DateTime.fromMillisecondsSinceEpoch(exportedAtRaw.toInt())
            : DateTime.now(),
        // 只认已知类别：文件里出现未知键（如手写范本里的 `_说明`）不算一类，
        // 不影响"带了哪些类别"的判断。
        provided: d.keys.where(knownSections.contains).toSet(),
        settings: _mapOf(d['settings']),
        searchHistory: _stringsOf(d['searchHistory']),
        readPositions: _mapOf(d['readPositions']),
        favouriteCollections: _mapOf(d['favouriteCollections']),
        voteOverlay: _mapOf(d['voteOverlay']),
        userRemarks: _mapOf(d['userRemarks']),
        contentCache: cache,
      );
    } catch (e) {
      log.w(LogTag.cache, '备份解析失败：$e');
      return null;
    }
  }

  /// 应用备份：按文件里出现的类别**覆盖式**写入本机同类数据，随后重载各内存态
  /// 并广播一次数据版本，让界面整体重新取数。
  ///
  /// 合并策略刻意保持简单：完整备份是"整机快照"，导入即还原快照 —— 逐条合并
  /// 会让续读点、合集墓碑、点赞覆盖层的语义变得难以推理，收益也不明显。
  /// 唯一的细化是**按类别取舍**（见 [BackupPayload.provided]）：文件没带的类别
  /// 一律不碰，这样手写的局部文件（如只带搜索词的范本）不会误清其它数据。
  static Future<BackupImportSummary> apply(BackupPayload p) async {
    final store = LocalStore.instance;
    final bridge = NativeBridge.instance;
    final has = p.provided.contains;

    if (has('settings')) {
      await store.write(LocalStore.keySettings, p.settings);
    }
    if (has('searchHistory')) {
      await store.write(LocalStore.keySearchHistory, p.searchHistory);
    }
    if (has('readPositions')) {
      await store.write(LocalStore.keyReadPositions, p.readPositions);
    }
    if (has('favouriteCollections')) {
      await store.write(LocalStore.keyFavCollections, p.favouriteCollections);
    }

    // 点赞覆盖层：文件没带就保留本机现有记录（历史上也从不做清空）。
    if (has('voteOverlay') && p.voteOverlay.isNotEmpty) {
      await bridge.kvSet(VoteOverlay.kvKey, jsonEncode(p.voteOverlay));
    }

    // 用户备注：与其余类别同一口径 —— 文件带了这个类别就整体替换
    //（空对象即"本机没有备注"，照旧覆盖）。
    if (has('userRemarks')) {
      await UserRemarksStore.instance.replaceAll(p.userRemarks);
    }

    var cacheWritten = 0;
    if (has('contentCache')) {
      for (final e in p.contentCache) {
        final ok = await bridge.fileWrite(
          ContentCache.fileNameFor(e.signature),
          jsonEncode({
            'sig': e.signature,
            'savedAt': e.savedAt,
            'rows': e.rows,
          }),
        );
        if (ok) cacheWritten++;
      }
    }

    // 重载内存态：设置与合集目录会通知监听者，界面随即刷新；
    // 续读点、搜索历史在下一次读取时自然生效。
    await AppSettings.instance.load();
    await SearchHistory.instance.load();
    await ReadingPositionStore.instance.load();
    await FavouriteCollectionsStore.instance.reloadFromDisk();
    await VoteOverlay.instance.reload();

    // 最后广播：搜索页/收藏页各自在 State 里持有已抓取的条目与游标，
    // 不订阅上面这些 store，只能靠这一下让外壳把它们整体重建。
    DataRevision.instance.bump();

    log.i(
      LogTag.cache,
      '备份已导入：类别 ${p.provided.isEmpty ? '（无）' : p.includedLabels.join('、')}；'
      '缓存 $cacheWritten 条、合集 ${p.collectionCount} 个、'
      '历史 ${p.historyCount} 条、续读点 ${p.readPositionCount} 个、'
      '备注 ${p.remarkCount} 条',
    );
    return BackupImportSummary(
      cacheEntries: cacheWritten,
      collections: p.collectionCount,
      historyItems: p.historyCount,
      readPositions: p.readPositionCount,
      remarks: p.remarkCount,
    );
  }

  static int _countCollections(Map<String, dynamic> fav) {
    final items = fav['items'];
    return items is Map ? items.length : 0;
  }

  static Map<String, dynamic> _mapOf(dynamic v) {
    if (v is! Map) return <String, dynamic>{};
    return v.map((k, val) => MapEntry(k.toString(), val));
  }

  static List<String> _stringsOf(dynamic v) {
    if (v is! List) return const <String>[];
    return v
        .map((e) => e?.toString() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
  }
}
