import 'package:flutter/foundation.dart';

import '../api/api_config.dart';
import '../api/api_exception.dart';
import '../api/models.dart';
import '../api/simple_api.dart';
import '../data/favourite_collections.dart';
import '../data/reading_positions.dart';
import '../util/app_log.dart';
import 'load_phase.dart';
import 'paged_list.dart';

/// 收藏夹（本机自建的「收藏的合集」）控制器。
///
/// 为什么是自建：探查报告 9.6 已把「按收藏人维度列合集」这条路封死 ——
/// `user_id` 的语义是「合集作者」，19 个收藏关系参数全部被服务端静默忽略，
/// 也没有任何写入端点。客户端能拿到「我收藏了哪个合集」的唯一途径，
/// 就是从**已收藏的动态**里读出它内嵌的 `post_collection`。
///
/// 因此本控制器只做两件事：
/// 1. 进入页面时抓一次最新的收藏动态列表（强制走网络），把其中的合集解析进本机库；
/// 2. 把本机库暴露给 UI，并支持单条删除（本地墓碑，见
///    [FavouriteCollectionsStore.remove]）。
class CollectionsController extends ChangeNotifier {
  CollectionsController({
    required this.tokenProvider,
    SimpleApi? api,
    FavouriteCollectionsStore? store,
  })  : _api = api ?? SimpleApi(),
        _store = store ?? FavouriteCollectionsStore.instance {
    // 订阅 / 红点 / 移除恢复都直接改 _store 并由它 notifyListeners，但 UI
    // 监听的是本控制器 —— 不转发的话界面永远停在旧数据上（实测表现：
    // 订阅铃铛点了不变色，而且按钮读到的还是旧对象，永远"只能订阅"）。
    _store.addListener(_onStoreChanged);
  }

  final SimpleApi _api;
  final FavouriteCollectionsStore _store;

  /// 每次请求实时取 token。
  final String? Function() tokenProvider;

  void Function(String message)? onAuthFailure;

  /// 仓库（订阅态 / 红点 / 元信息）变化 → 通知 UI。
  void _onStoreChanged() => _notify();

  bool _busy = false;
  bool _syncedOnce = false;

  /// 单次同步最多补几条元信息（每条一次 v3 单条请求，受限速约束）。
  static const int _maxMetaFillPerSync = 5;

  /// 完整同步时允许补更多条元信息：完整同步本来就是「一次做到底」的操作。
  static const int _maxMetaFillFullSync = 12;

  /// 单次完整同步最多翻多少页（每页 10 条 → 200 页 = 2000 条收藏动态）。
  ///
  /// 存在的意义是防止服务端游标异常时无限翻页（限速下每页至少 1.2 秒）。
  static const int maxFullPages = 200;

  LoadPhase _phase = LoadPhase.idle;
  String? _error;

  /// 本次同步新收录的合集条数（-1 表示这次没同步成功）。
  int _addedLastSync = -1;

  /// 本次同步解析到的收藏动态条数。
  int _scannedLastSync = 0;

  /// 上一次同步是否走的完整同步。
  bool _lastSyncWasFull = false;

  /// 当前是否正在完整同步。
  bool _fullSyncing = false;

  /// 完整同步已翻页数。
  int _fullPagesScanned = 0;

  /// 同步进度文案（完整同步时逐页更新）。
  String? _progress;

  DateTime? _syncedAt;
  DateTime? _fullSyncedAt;

  /// 本机库条目。
  List<FavCollection> get items => _store.items;

  /// 按 id 取一条（UI 切换订阅态时用它读最新值，避免拿着旧对象取反）。
  FavCollection? byId(String id) => _store.byId(id);

  int get length => _store.length;

  /// 被本机删除过的合集数量（可以恢复）。
  int get removedCount => _store.removedCount;

  bool get busy => _busy;

  bool get syncedOnce => _syncedOnce;

  LoadPhase get phase => _phase;

  String? get error => _error;

  int get addedLastSync => _addedLastSync;

  int get scannedLastSync => _scannedLastSync;

  /// 上一次同步是否为完整同步。
  bool get lastSyncWasFull => _lastSyncWasFull;

  /// 是否正在完整同步。
  bool get fullSyncing => _fullSyncing;

  /// 完整同步已翻页数。
  int get fullPagesScanned => _fullPagesScanned;

  /// 同步进度文案（完整同步逐页更新，结束后为 null）。
  String? get progress => _progress;

  DateTime? get syncedAt => _syncedAt;

  /// 最近一次完整同步完成时间。
  DateTime? get fullSyncedAt => _fullSyncedAt;

  /// 本次同步新收录的合集 id，UI 可用它高亮。
  Set<String> get lastAddedIds => _store.lastAddedIds;

  /// 库为空且同步完成过 —— 真正的「没有可展示的合集」。
  bool get isEmptyResult =>
      _syncedOnce && _store.isEmpty && _phase == LoadPhase.ready && !_busy;

  /// 上次同步的提示语。
  String? get syncNotice {
    if (_addedLastSync < 0 || _scannedLastSync <= 0) return null;
    final what = _lastSyncWasFull ? '完整同步' : '本次同步';
    if (_addedLastSync > 0) {
      return '$what：从 $_scannedLastSync 条收藏动态里解析到 $_addedLastSync 个新合集';
    }
    return '$what：已解析 $_scannedLastSync 条收藏动态，没有发现新合集';
  }

  /// 页面是否已销毁。
  ///
  /// 完整同步可能持续数分钟（每页至少 1.2 秒），用户中途退出页面是常态：
  /// 此时 controller 已被 dispose，再 `notifyListeners()` 会踩到
  /// "用在已 dispose 的对象上"的断言。所有通知统一走 [_notify]。
  bool _disposed = false;

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    _disposed = true;
    super.dispose();
  }

  /// 抓取收藏动态列表并解析合集。
  ///
  /// 调用方只有一处：收藏页「收藏的合集」视图 AppBar 上那个唯一的同步按钮
  /// （`FavoritesCollectionsViewState.syncSmart`）。它按本机目录是否为空选择口径：
  ///
  /// * `full = false`（已有数据）：只抓**最新一页**（10 条），固定走
  ///   [CacheMode.networkFirst] —— 每次点都看最新的收藏动态，命中本地缓存就
  ///   失去意义了。网络失败时回落到上一次的缓存结果，至少不会把列表清空。
  /// * `full = true`（本机目录为空、尚未初始化）：沿游标逐页翻遍**全部**收藏
  ///   动态，把历史上收藏过的合集一次性解析进本机目录。只抓最新 10 条常常
  ///   一条合集都解析不到（历史收藏都在更早的页），所以初始化必须全量。
  ///   每页仍是 10 条、请求串行且间隔由 [ApiClient] 统一限制（≥1.2 秒），
  ///   每翻完一页就落盘并推进进度，中途失败也已保留已完成的部分。附带好处：
  ///   全部收藏动态会被写进内容缓存，之后离线（续读模式）也能翻。
  Future<void> sync({bool full = false}) async {
    if (_busy) return;
    final token = tokenProvider();
    if (token == null || token.isEmpty) {
      _phase = LoadPhase.error;
      _error = '尚未配置 token';
      log.w(LogTag.fav, '同步中止：尚未配置 token');
      _notify();
      return;
    }

    _busy = true;
    _fullSyncing = full;
    _fullPagesScanned = 0;
    _progress = full ? '准备开始完整同步…' : null;
    if (_store.isEmpty) _phase = LoadPhase.loadingFirst;
    _error = null;
    // 「新收录」标记按整轮同步统计，这里先清空（absorbFromPosts 会累加）。
    _store.clearLastAdded();
    _notify();

    final sw = Stopwatch()..start();
    log.i(
      LogTag.fav,
      '开始${full ? '完整' : '常规'}同步收藏动态'
      '（每页 ${ApiConfig.defaultPerPage} 条，'
      '${full ? '最多 $maxFullPages 页' : '仅最新一页'}）',
    );

    var scanned = 0;
    var added = 0;
    var pages = 0;
    var lastId = '';

    try {
      while (true) {
        pages++;
        _fullPagesScanned = pages;
        if (full) {
          _progress = '正在完整同步：第 $pages 页，已解析 $scanned 条动态';
          _notify();
        }

        final page = await _api.fetchFavourites(
          token: token,
          lastId: lastId,
          perPage: ApiConfig.defaultPerPage,
          mode: CacheMode.networkFirst,
        );

        added += _store.absorbFromPosts(page.items);
        scanned += page.items.length;
        log.d(
          LogTag.fav,
          '第 $pages 页：${page.items.length} 条动态，'
          '累计新收录 ${_store.lastAddedIds.length} 个，hasMore=${page.hasMore}',
        );

        if (!full) break;
        if (page.items.isEmpty || !page.hasMore) break;
        final next = page.nextCursor;
        if (next == null || next.isEmpty) break;
        lastId = next;
        if (pages >= maxFullPages) {
          log.w(LogTag.fav, '达到单次完整同步的页数上限（$maxFullPages 页），提前结束');
          break;
        }
      }

      _addedLastSync = added;
      _scannedLastSync = scanned;
      _lastSyncWasFull = full;
      _syncedAt = DateTime.now();
      if (full) {
        _fullSyncedAt = _syncedAt;
        // 首次自动全量只做一次：标记落盘后，冷启动再进本页只抓最新一页。
        await _store.markAutoFullSynced();
      }

      // 内嵌合集对象可能整键缺失（见 absorbFromPosts 注释），这里补一次元信息，
      // 否则这类条目在列表里只能显示"未命名合集"。
      _progress = full ? '正在补齐合集元信息…' : null;
      _notify();
      await _fillMissingMeta(
        token,
        limit: full ? _maxMetaFillFullSync : _maxMetaFillPerSync,
      );

      _syncedOnce = true;
      _phase = LoadPhase.ready;
      log.i(
        LogTag.fav,
        '${full ? '完整' : '常规'}同步完成：$pages 页 / $scanned 条动态，'
        '新收录 $added 个，本机库共 ${_store.length} 个${AppLog.ms(sw)}',
      );
    } on ApiException catch (e) {
      _error = e.message;
      // 已经有本地库时不切到整页错误态：让用户至少还能用已收录的合集。
      if (_store.isEmpty) _phase = LoadPhase.error;
      log.e(
        LogTag.fav,
        '同步失败（已完成 $pages 页 / $scanned 条，新收录 $added 个）：${e.message}',
      );
      if (e.requiresReauth) onAuthFailure?.call(e.message);
    } catch (e, st) {
      _error = '同步收藏动态失败：$e';
      if (_store.isEmpty) _phase = LoadPhase.error;
      log.exception(LogTag.fav, '同步异常（已完成 $pages 页）', e, st);
    } finally {
      _busy = false;
      _fullSyncing = false;
      _progress = null;
      _addedLastSync = added;
      _scannedLastSync = scanned;
      _notify();
    }
  }

  /// 从本机收藏夹移除一条。只影响本机，官方端状态不变。
  Future<void> remove(String id) async {
    final name = _store.byId(id)?.name ?? id;
    await _store.remove(id);
    log.i(LogTag.fav, '从本机收藏夹移除：$name（$id）');
  }

  /// 设置 / 取消订阅合集（订阅后冷启动会扫描新动态，见
  /// [SubscriptionScanner]）。
  Future<void> setSubscribed(String id, bool value) =>
      _store.setSubscribed(id, value);

  /// 用户点开了合集：清除新动态红点并把基线推进到当前最新一条。
  Future<void> markSeen(String id, String topPostId) =>
      _store.markSeen(id, topPostId);

  /// 恢复本机删除过的合集。下次同步解析到才会重新出现。
  Future<void> restoreRemoved() async {
    final n = _store.removedCount;
    await _store.restoreRemoved();
    log.i(LogTag.fav, '取消移除记录：$n 个合集，下次同步会重新收录');
  }

  /// 补齐元信息不全的条目。
  ///
  /// 触发场景：`visibility = collection_visibility` 的合集在动态里**不带**
  /// `post_collection` 内嵌对象（整键缺失，实测），收录时只能先记下 id，
  /// 名称与条数由 `GET api/v3/post_collections/{id}` 补 —— 该接口对这类合集
  /// 同样返回 200（实测「实用工具🔧」与「🅰️🈂️💱」两条均如此）。
  ///
  /// 请求由 ApiClient 统一限速；这里再限制单次补齐条数，避免首次进入等待过久，
  /// 补失败的条目留到下次进入再补。
  Future<void> _fillMissingMeta(String token, {required int limit}) async {
    final pending = _store.idsMissingMeta.take(limit).toList();
    if (pending.isEmpty) return;
    log.i(LogTag.fav, '需补齐元信息的合集：${pending.length} 个（本次最多补 $limit 个）');
    for (final id in pending) {
      try {
        final meta =
            await _api.fetchCollectionMeta(token: token, collectionId: id);
        if (meta == null) continue;
        await _store.updateMeta(
          id: id,
          name: meta.name.isNotEmpty ? meta.name : null,
          description: meta.description.isNotEmpty ? meta.description : null,
          postsCount: meta.postsCount >= 0 ? meta.postsCount : null,
          authorId: meta.userId.isNotEmpty ? meta.userId : null,
        );
        log.d(
          LogTag.fav,
          '元信息已补：$id → ${meta.name}（${meta.postsCount} 条）',
        );
      } catch (e) {
        // 单条补失败不影响其余条目，也不该让整次同步失败。
        log.w(LogTag.fav, '补元信息失败：$id｜$e');
      }
    }
  }

  /// 清掉「新收录」高亮标记。
  void clearLastAdded() => _store.clearLastAdded();

  /// 一键清空本机收藏夹。
  Future<void> clearAll() async {
    final n = _store.length;
    await _store.clear();
    log.i(LogTag.fav, '清空本机收藏夹：$n 个合集');
  }
}

/// 某个合集内动态的分页控制器。
///
/// 复用 [PagedListController]，因此合集内同样是「10 条一页 + 双向补页 + 续读」。
/// 取数口径见 [SimpleApi.fetchCollectionPosts]：必须同时带作者与合集两个参数。
class CollectionPostsController extends PagedListController {
  CollectionPostsController({
    required super.tokenProvider,
    required this.collectionId,
    required this.authorId,
    required this.mine,
    SimpleApi? api,
  }) : _api = api ?? SimpleApi();

  final SimpleApi _api;
  final String collectionId;

  /// 合集作者 ID。合集内容必须按「作者 + 合集」双参数过滤。
  final String authorId;

  /// 合集是否属于当前登录用户（决定走 `posts/mine` 还是 `posts/profile`）。
  final bool mine;

  /// 实际使用的取数口径，供 UI 排查用。
  String get paramLabel => _api.resolvedCollectionPostsLabel;

  @override
  String get scope => ReadScope.collection(collectionId);

  @override
  Future<PageResult<Post>> fetchPage({
    required String token,
    required String lastId,
    required CacheMode mode,
  }) =>
      _api.fetchCollectionPosts(
        token: token,
        collectionId: collectionId,
        authorId: authorId,
        mine: mine,
        lastId: lastId,
        perPage: ApiConfig.defaultPerPage,
        mode: mode,
      );

  Future<void> ensureLoaded() async {
    if (loadedOnce || busy) return;
    ran = true;
    beginLoad();
    await loadPage(0);
    finishLoad();
  }
}
