import 'package:flutter/foundation.dart';

import '../api/api_config.dart';
import '../api/api_exception.dart';
import '../api/models.dart';
import '../api/simple_api.dart';
import '../data/settings.dart';
import '../util/app_log.dart';

/// 「综合阅读」取一页的函数签名。
///
/// 与 [SimpleApi.searchPosts] 的具名参数一一对应；抽成函数类型是为了在
/// 测试里注入假实现（工程零第三方依赖，不做 mock 框架）。
typedef AggregateFetcher = Future<PageResult<Post>> Function({
  required String keyword,
  required String token,
  String lastId,
  int perPage,
  CacheMode mode,
});

/// 「综合阅读」控制器：多关键词合并的按发布时间排序瀑布流。
///
/// 与 [PagedListController] 的区别：内容不是"一个关键词的翻页序列"，而是
/// 多个关键词各取一页、按发布时间**全局合并排序**的单条时间线 —— 页边界
/// 在这里没有意义（需求：不在界面上标注不同搜索词抓到的内容），因此不复用
/// 分页控制器的游标语义，自己维护每个关键词各自的游标链。
///
/// 取数节奏：
/// * 一轮 = 对每个"还有下一页"的关键词各取一页（接口本身串行限速 ≥1.2s）；
/// * 首轮由「综合阅读」入口触发，默认优先读缓存（点刷新才强制联网）；
/// * 列表滑到底再取下一轮（内容更旧），直到所有关键词都到服务端尽头。
///
/// 「上次浏览到这儿」分界（与单关键词搜索同一套语义，2026-10-09 追加需求）：
/// * 每次 [start] 前把上一批内容按**关键词分别**留档（哪个词抓到过哪些内容）；
/// * 强制联网的重新抓取（刷新 / 再次打开）会自动一轮轮往下抓，**每个关键词
///   各自**碰到"自己上次抓到过的内容"即停 —— 各自独立，不互相等待；
/// * 分界**只作为抓取停止的触发点**，合并列表里不插分界条（用户口径）。
class AggregateFeedController extends ChangeNotifier {
  AggregateFeedController({required this.tokenProvider, required this.fetcher});

  /// 每次请求实时取 token，避免控制器持有旧值。
  final String? Function() tokenProvider;

  /// 取一页数据（按关键词）。
  final AggregateFetcher fetcher;

  /// 收到 401/403 时冒泡到全局状态。
  void Function(String message)? onAuthFailure;

  /// 单个关键词的翻页防御上限（页）。
  static const int maxPagesPerKeyword = 50;

  /// 自动续抓到分界的轮数上限（防御：热词可能一直碰不到上次内容）。
  static const int maxAutoFetchRounds = 30;

  final Map<String, _KeywordFeed> _feeds = <String, _KeywordFeed>{};
  final List<String> _keywords = <String>[];
  final List<Post> _posts = <Post>[];

  /// 条目入库顺序（同一发布时间时保持稳定排序的兜底）。
  final Map<String, int> _order = <String, int>{};
  int _nextOrder = 0;

  /// 上一批内容：按关键词留档的"抓到过哪些条目"（重抓时判分界用）。
  Map<String, Set<String>> _prevByKeyword = <String, Set<String>>{};
  Set<String> _prevUnion = <String>{};

  bool _ran = false;
  bool _loading = false;
  bool _loadingMore = false;
  bool _autoFetching = false;
  String? _autoFetchStopReason;
  bool _lastRoundHadErrors = false;
  bool _fromCache = false;
  DateTime? _cachedAt;
  String? _error;
  int _rounds = 0;
  int _progressDone = 0;
  int _progressTotal = 0;
  int _filtered = 0;

  /// 是否已经发起过取数。
  bool get ran => _ran;

  /// 首轮 / 刷新是否进行中（整屏等待态）。
  bool get loading => _loading;

  /// 是否正在追加载更早的一轮（列表底部转圈）。
  bool get loadingMore => _loadingMore;

  /// 是否正在"自动续抓到分界"（占用整屏等待态，见 [_autoFetchToBoundary]）。
  bool get autoFetching => _autoFetching;

  bool get busy => _loading || _loadingMore || _autoFetching;

  /// 上一次自动续抓的结束原因：`boundary` / `end` / `limit` / `error`。
  String? get autoFetchStopReason => _autoFetchStopReason;

  /// 本轮关键词抓取失败过（底部提示可重试；重试前不自动追加载）。
  bool get lastRoundHadErrors => _lastRoundHadErrors;

  /// 本次加载使用过的关键词名单（顺序即历史顺序）。
  List<String> get keywords => List.unmodifiable(_keywords);

  /// 合并后的内容，按发布时间从新到旧。
  List<Post> get posts => List.unmodifiable(_posts);

  int get itemCount => _posts.length;

  /// 整屏错误（全部关键词都失败 / 未配置 token）。
  String? get error => _error;

  /// 内容是否全部来自本地缓存（用于状态条提示）。
  bool get fromCache => _fromCache;

  /// 缓存写入时间（取最近一次缓存时间）。
  DateTime? get cachedAt => _cachedAt;

  /// 本轮进度（用于"已抓取 3/6 个关键词"）。
  int get progressDone => _progressDone;
  int get progressTotal => _progressTotal;

  /// 已完成的轮数。
  int get rounds => _rounds;

  /// 被屏蔽关键词过滤掉的条数（与搜索页同口径）。
  int get filteredCount => _filtered;

  /// 还有更早的内容可抓（服务端还有下一页且未到防御上限）。
  bool get hasMore {
    if (!_ran) return false;
    return _feeds.values.any((f) => f.hasMore);
  }

  /// 「上次浏览到这儿」分界在 [posts] 里的位置（第一条上次看过的条目）。
  ///
  /// ⚠️ 仅用于日志/排查：用户口径（2026-10-09）——分界**只作为抓取停止的
  /// 触发点**，合并列表里不插分界条。返回 null = 没有可分界的旧内容。
  int? get boundaryIndex {
    if (_prevUnion.isEmpty || _posts.isEmpty) return null;
    for (var i = 0; i < _posts.length; i++) {
      if (_prevUnion.contains(_posts[i].id)) return i > 0 ? i : null;
    }
    return null;
  }

  /// 关键词覆盖的抓取是否已全部到尽头（有内容、但都没下一页了）。
  bool get exhausted => _ran && _posts.isNotEmpty && !hasMore && !busy;

  /// 抓取成功过但一条都没有。
  bool get isEmptyResult => _ran && _posts.isEmpty && !busy && _error == null;

  /// 关键词名单是否与给定名单一致（设置页改过名单后据此判断需要重来）。
  bool matchesKeywords(List<String> list) {
    final next = list
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (next.length != _keywords.length) return false;
    for (var i = 0; i < next.length; i++) {
      if (_keywords[i] != next[i]) return false;
    }
    return true;
  }

  /// 从头加载（进入综合阅读 / 刷新）。
  ///
  /// [forceNetwork] 为 true 时首轮强制联网（"刷新"按钮 / 再次打开）：
  /// 抓完首轮会继续自动往下抓，**每个关键词各自**接到"上次浏览到这儿"
  /// 才停（[autoFetchStopReason] == `boundary`）；分界只作停止触发点，
  /// 不在列表里插条（用户口径 2026-10-09）。
  /// 默认优先缓存（抓过的内容秒开、不打扰服务端），此时不做自动续抓。
  Future<void> start(List<String> keywords, {bool forceNetwork = false}) async {
    if (busy) return;

    // 上一批内容留档（按关键词分别记）—— 必须在换血之前拍快照。
    _prevByKeyword = {
      for (final e in _feeds.entries)
        if (e.value.seenIds.isNotEmpty) e.key: Set<String>.of(e.value.seenIds),
    };
    _prevUnion = {
      for (final s in _prevByKeyword.values) ...s,
    };

    _keywords
      ..clear()
      ..addAll(
        keywords.map((e) => e.trim()).where((e) => e.isNotEmpty),
      );
    _feeds
      ..clear();
    for (final k in _keywords) {
      _feeds[k] = _KeywordFeed(k);
    }
    _posts.clear();
    _order.clear();
    _nextOrder = 0;
    _filtered = 0;
    _error = null;
    _fromCache = false;
    _cachedAt = null;
    _rounds = 0;
    _lastRoundHadErrors = false;
    _autoFetchStopReason = null;
    _autoFetching = false;
    _ran = true;
    _loading = true;
    _progressDone = 0;
    _progressTotal = _keywords.length;
    notifyListeners();

    if (_keywords.isEmpty) {
      _loading = false;
      notifyListeners();
      return;
    }

    log.i(
      LogTag.page,
      '综合阅读开始：${_keywords.length} 个关键词'
      '（${forceNetwork ? '刷新（强制联网）' : '优先缓存'}）'
      '${_prevUnion.isEmpty ? '' : '，上次留档 ${_prevUnion.length} 条'}',
    );
    await _fetchRound(forceNetwork: forceNetwork);
    log.i(
      LogTag.page,
      '综合阅读首轮完成：${_posts.length} 条'
      '${_filtered > 0 ? '（屏蔽词过滤 $_filtered 条）' : ''}',
    );
    notifyListeners();

    // 续抓到分界期间保持整屏等待态（_loading 一起压着，避免中途闪一下列表）。
    if (forceNetwork && _prevUnion.isNotEmpty && _autoPhaseWantsMore) {
      await _autoFetchToBoundary();
    }
    _loading = false;
    notifyListeners();
  }

  /// 追加载一轮（每个还有下一页的关键词各再取一页，内容更旧）。
  ///
  /// 这是"往下读"的路径（滑到底自动触发）：不受分界限制 —— 分界只是
  /// 标记"上次读到这儿"，用户想看更早的内容就继续往下抓（与搜索页一致）。
  Future<void> loadMore() async {
    if (busy || !hasMore) return;
    _loadingMore = true;
    _progressDone = 0;
    _progressTotal = 0;
    _lastRoundHadErrors = false;
    notifyListeners();
    await _fetchRound(forceNetwork: false);
    _loadingMore = false;
    notifyListeners();
  }

  /// 清空（关键词名单清空时由 UI 调用）。
  void reset() {
    _keywords.clear();
    _feeds.clear();
    _posts.clear();
    _order.clear();
    _nextOrder = 0;
    _prevByKeyword = <String, Set<String>>{};
    _prevUnion = <String>{};
    _filtered = 0;
    _error = null;
    _fromCache = false;
    _cachedAt = null;
    _rounds = 0;
    _ran = false;
    _loading = false;
    _loadingMore = false;
    _autoFetching = false;
    _autoFetchStopReason = null;
    _lastRoundHadErrors = false;
    notifyListeners();
  }

  /// 自动续抓是否还有"该抓的词"：某个词还没接上它自己的上次内容、
  /// 且它上次确实有留档（新词没有分界可依，不参与自动续抓）。
  bool get _autoPhaseWantsMore => _feeds.values.any(
        (f) =>
            f.hasMore &&
            !f.connected &&
            _prevByKeyword.containsKey(f.keyword),
      );

  /// 自动续抓到分界：每个关键词**各自**碰到上次抓到过的内容即停。
  ///
  /// 停止条件（先命中先停）：
  /// * `boundary` —— 所有该接的词都接上了（各词独立判定）；
  /// * `end` —— 没有下一个可抓的页（服务端到底 / 已达页数上限）；
  /// * `error` —— 有词抓取失败（不静默重试，交由底部「重试」）；
  /// * `limit` —— 达到 [maxAutoFetchRounds]（防御：热词可能永远碰不到旧内容）。
  Future<void> _autoFetchToBoundary() async {
    _autoFetching = true;
    _autoFetchStopReason = null;
    _progressDone = 0;
    _progressTotal = 0;
    notifyListeners();
    log.i(
      LogTag.page,
      '综合阅读：自动续抓到「上次浏览到这儿」分界'
      '（上次留档 ${_prevUnion.length} 条，上限 $maxAutoFetchRounds 轮）',
    );

    var rounds = 0;
    var reason = 'boundary';
    try {
      while (true) {
        if (!_autoPhaseWantsMore) {
          reason = 'boundary';
          break;
        }
        if (!hasMore) {
          reason = 'end';
          break;
        }
        if (_lastRoundHadErrors) {
          reason = 'error';
          break;
        }
        if (rounds >= maxAutoFetchRounds) {
          reason = 'limit';
          break;
        }
        await _fetchRound(forceNetwork: false, autoPhase: true);
        rounds++;
      }
      _autoFetchStopReason = reason;
      if (reason == 'boundary') {
        log.i(
          LogTag.page,
          '综合阅读续抓完成：又抓 $rounds 轮后各词接上上次内容'
          '（分界在第 ${(boundaryIndex ?? -1) + 1} 条，共 ${_posts.length} 条）',
        );
      } else if (reason == 'end') {
        log.i(LogTag.page, '综合阅读续抓结束：服务端已无更多（又抓 $rounds 轮，共 ${_posts.length} 条）');
      } else if (reason == 'limit') {
        log.w(LogTag.page, '综合阅读续抓终止：已达 $maxAutoFetchRounds 轮上限，仍有词没接上上次内容');
      } else {
        log.w(LogTag.page, '综合阅读续抓中止：有词抓取失败（又抓 $rounds 轮）');
      }
    } finally {
      _autoFetching = false;
      notifyListeners();
    }
  }

  /// 取一轮：逐个关键词串行取下一页（接口自身限速），合并去重后重排。
  ///
  /// [autoPhase] 为 true 时跳过已经接上分界的词（自动续抓专用）。
  Future<void> _fetchRound({
    required bool forceNetwork,
    bool autoPhase = false,
  }) async {
    final token = tokenProvider();
    if (token == null || token.isEmpty) {
      _error = '尚未配置 token';
      log.w(LogTag.page, '综合阅读取数中止：尚未配置 token');
      return;
    }

    _rounds++;
    _progressDone = 0;
    _progressTotal = 0;
    var anyCache = false;
    var anyNetwork = false;
    DateTime? latestCacheAt;
    var failed = 0;

    for (final feed in _feeds.values) {
      if (!feed.hasMore) continue;
      // 自动续抓只推进"有上次留档、还没接上分界"的词：新词没有分界可依，
      // 已接上的词再往下抓就是重复劳动（各自独立，不互相牵连）。
      if (autoPhase &&
          (feed.connected || !_prevByKeyword.containsKey(feed.keyword))) {
        continue;
      }
      _progressTotal++;

      try {
        final page = await fetcher(
          keyword: feed.keyword,
          token: token,
          lastId: feed.lastId,
          perPage: ApiConfig.defaultPerPage,
          mode: forceNetwork ? CacheMode.networkFirst : CacheMode.preferCache,
        );

        feed.pagesFetched++;
        final next = page.nextCursor ?? '';
        feed.lastId = next;
        feed.hasMore = page.hasMore && next.isNotEmpty;
        if (feed.hasMore && feed.pagesFetched >= maxPagesPerKeyword) {
          feed.hasMore = false;
          feed.stalled = true;
          log.w(
            LogTag.page,
            '综合阅读：「${feed.keyword}」已达单关键词 $maxPagesPerKeyword 页上限，停止继续下翻',
          );
        }

        if (page.fromCache) {
          anyCache = true;
          final at = page.cachedAt;
          if (at != null &&
              (latestCacheAt == null || at.isAfter(latestCacheAt))) {
            latestCacheAt = at;
          }
        } else {
          anyNetwork = true;
        }

        // 分界判定按**关键词分别**进行：这个词抓到的页里出现它上次抓到过
        // 的条目，即"接上上次浏览的位置"，该词本轮以后不再自动续抓。
        final prev = _prevByKeyword[feed.keyword];
        var connected = false;
        var kept = 0;
        for (final post in page.items) {
          if (post.id.isEmpty) continue;
          feed.seenIds.add(post.id);
          if (prev != null && prev.contains(post.id)) connected = true;
          if (AppSettings.instance.matchesBlockedKeyword(post.content)) {
            _filtered++;
            continue;
          }
          if (_order.containsKey(post.id)) continue; // 多关键词重复内容只留一条
          _order[post.id] = _nextOrder++;
          _posts.add(post);
          kept++;
        }
        if (connected && !feed.connected) {
          feed.connected = true;
          log.i(
            LogTag.page,
            '综合阅读：「${feed.keyword}」接上「上次浏览到这儿」'
            '（第 ${feed.pagesFetched} 页）',
          );
        }
        log.d(
          LogTag.page,
          '综合阅读：「${feed.keyword}」第 ${feed.pagesFetched} 页 +$kept 条'
          '（${page.fromCache ? '缓存' : '网络'}）'
          '${feed.connected ? '，已接上分界' : ''}',
        );
      } on ApiException catch (e) {
        failed++;
        feed.error = e.message;
        log.w(LogTag.page, '综合阅读：「${feed.keyword}」取数失败：${e.message}');
        if (e.requiresReauth) onAuthFailure?.call(e.message);
      } catch (e) {
        failed++;
        feed.error = '$e';
        log.w(LogTag.page, '综合阅读：「${feed.keyword}」取数异常：$e');
      }

      _progressDone++;
      notifyListeners();
    }

    _sortPosts();
    _fromCache = anyCache && !anyNetwork;
    if (latestCacheAt != null) _cachedAt = latestCacheAt;
    _lastRoundHadErrors = failed > 0;
    if (_posts.isEmpty && failed > 0) {
      _error = '取数失败：$failed 个关键词都没抓到内容，请稍后重试';
    } else if (_posts.isNotEmpty) {
      // 有内容就不整屏报错；单关键词失败由底部提示兜住。
      _error = null;
    }
    notifyListeners();
  }

  /// 按发布时间从新到旧（无时间的排最后，同时间保持入库顺序）。
  void _sortPosts() {
    _posts.sort((a, b) {
      final ta = a.createdAt?.millisecondsSinceEpoch;
      final tb = b.createdAt?.millisecondsSinceEpoch;
      if (ta != null && tb != null) {
        if (ta != tb) return tb.compareTo(ta);
      } else if (ta != null) {
        return -1;
      } else if (tb != null) {
        return 1;
      }
      return (_order[a.id] ?? 0).compareTo(_order[b.id] ?? 0);
    });
  }
}

/// 单个关键词的取数进度。
class _KeywordFeed {
  _KeywordFeed(this.keyword);

  final String keyword;

  /// 下一次请求要带的游标（首轮为空串）。
  String lastId = '';

  /// 已成功取过的页数。
  int pagesFetched = 0;

  /// 服务端还有下一页（且未达防御上限）。
  bool hasMore = true;

  /// 是否已接上"自己上次抓过的内容"（自动续抓的停止条件，按词独立）。
  bool connected = false;

  /// 本会话这个关键词抓到过的全部条目 id（下次重抓时的分界依据）。
  final Set<String> seenIds = <String>{};

  /// 是否因防御上限而停止（供日志/提示区分"服务端到底"）。
  bool stalled = false;

  /// 最近一次失败原因。
  String? error;
}
