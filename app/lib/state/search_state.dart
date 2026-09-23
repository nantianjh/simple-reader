import 'package:flutter/foundation.dart' show listEquals;

import '../api/api_config.dart';
import '../api/models.dart';
import '../api/simple_api.dart';
import '../data/reading_positions.dart';
import '../data/search_history.dart';
import '../data/settings.dart';
import '../util/app_log.dart';
import 'load_phase.dart';
import 'paged_list.dart';

/// 搜索结果控制器。
///
/// 命名为 [SearchPageController] 而非 `SearchController`，是为了避开
/// Material 3 自带的同名类（`SearchAnchor` 使用），否则会产生导入歧义。
///
/// 结果按 10 条一页组织（见 [PagedListController]），续读点记录页号，
/// 因此「续读」可以直接跳回第 N 页，并在跳过去之后继续向上/向下翻页。
///
/// v1.7.2 新增屏蔽关键词：正文完整包含任一关键词的动态在入库前被剔除
/// （[shouldKeepPost]）；会话中途修改关键词时，已加载的内容也会立即
/// 剔除命中项（[_onSettingsChanged]）。
class SearchPageController extends PagedListController {
  SearchPageController({
    required super.tokenProvider,
    SimpleApi? api,
  }) : _api = api ?? SimpleApi() {
    AppSettings.instance.addListener(_onSettingsChanged);
    _lastKeywords = AppSettings.instance.blockedKeywords;
  }

  final SimpleApi _api;

  String _keyword = '';

  String get keyword => _keyword;

  /// 是否已经执行过搜索。
  bool get hasSearched => ran;

  /// 上一次应用过的屏蔽词集合（变更检测用）。
  List<String> _lastKeywords = const <String>[];

  @override
  String get scope => ReadScope.search(_keyword);

  @override
  Future<PageResult<Post>> fetchPage({
    required String token,
    required String lastId,
    required CacheMode mode,
  }) =>
      _api.searchPosts(
        keyword: _keyword,
        token: token,
        lastId: lastId,
        perPage: ApiConfig.defaultPerPage,
        mode: mode,
      );

  @override
  bool shouldKeepPost(Post post) =>
      !AppSettings.instance.matchesBlockedKeyword(post.content);

  @override
  Future<bool?> probePageCache({required int page, required String lastId}) =>
      _api.hasCachedSearchPage(keyword: _keyword, lastId: lastId);

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  /// 屏蔽关键词变化时：把新规则立即套到已加载的内容上（移除命中项）。
  ///
  /// 只做"移除"、不做"恢复"：此前被过滤掉的条目本地已不保留，
  /// 删除关键词后要重新看到，下拉刷新即可（重新抓取按新规则入库）。
  void _onSettingsChanged() {
    final now = AppSettings.instance.blockedKeywords;
    if (listEquals(now, _lastKeywords)) return;
    _lastKeywords = now;
    if (now.isEmpty || !ran) return;
    final removed = removePostsWhere(
      (p) => AppSettings.instance.matchesBlockedKeyword(p.content),
    );
    if (removed > 0) {
      addFilteredCount(removed);
      log.i(LogTag.page, '屏蔽关键词变更：从已加载结果中移除 $removed 条');
    }
  }

  /// 查询某个关键词的续读点（不改变当前状态）。
  ReadingPosition? positionFor(String keyword) {
    final q = keyword.trim();
    if (q.isEmpty) return null;
    return ReadingPositionStore.instance.get(ReadScope.search(q));
  }

  /// 执行搜索。
  ///
  /// [resumeAt] 非 null 表示这是「续读上次位置」：直接跳到存档页号，
  /// 且整个过程只读本地缓存，不产生新的抓取请求；本地确实没有那一页时
  /// 才回落到联网。
  ///
  /// [forceNetwork] 为 true 时第 1 页强制联网（networkFirst）—— 同一个词
  /// 再次提交表示「要新内容」，此时第 1 页若仍走 preferCache 会命中旧
  /// 缓存，等于什么都没发生；切换到别的词不应触发联网重抓。
  Future<void> search(
    String keyword, {
    ReadingPosition? resumeAt,
    bool forceNetwork = false,
  }) async {
    final q = keyword.trim();
    if (q.isEmpty) return;

    _keyword = q;
    // 「上次浏览到这儿」分界的快照：新检索（非续读）算一次会话性抓取，
    // 当前已加载的内容就是"上次浏览的"；续读全程读缓存、不产生新抓取，
    // 快照清掉，避免在缓存内容里误标分界。
    if (resumeAt == null) {
      snapshotPrevSession();
    } else {
      clearPrevSessionSnapshot();
    }
    reset();
    ran = true;
    // 过滤计数从本次检索起算，屏蔽词以当前设置为准。
    _lastKeywords = AppSettings.instance.blockedKeywords;
    offlineReading = resumeAt != null;
    // 续读靠存档里的游标链直接寻址到第 N 页，不必从第一页重走；
    // 缓存深度一并恢复 —— 跳页上限要能覆盖「上次缓存的所有页」。
    if (resumeAt != null) {
      adoptCursors(resumeAt.cursors);
      await restoreCachedDeepPage(resumeAt);
    }
    beginLoad();

    log.i(
      LogTag.page,
      '搜索「$q」${resumeAt != null ? '（续读，第 ${resumeAt.page + 1} 页）' : forceNetwork ? '（强制联网重抓，从第 1 页开始）' : '（从第 1 页开始）'}'
      '${_lastKeywords.isNotEmpty ? '，屏蔽词 ${_lastKeywords.length} 个' : ''}',
    );

    // 记入搜索历史（失败不影响搜索）。
    await SearchHistory.instance.add(q);

    final target = resumeAt != null ? resumeAt.page : 0;
    final mode = resumeAt != null
        ? CacheMode.cacheOnly
        : forceNetwork
            ? CacheMode.networkFirst
            : CacheMode.preferCache;

    final ok = await loadPage(target, mode: mode);

    // 存档点语义：续读只读缓存。目标页无缓存说明存档已失效（如过保留期），
    // 不联网兜底 —— 空列表 + 如实提示，由用户显式下拉刷新或点搜索重新联网。
    // 已经出错（phase == error）则走错误展示，不重复提示。
    if (!ok && phase == LoadPhase.loadingFirst && resumeAt != null) {
      log.i(LogTag.read, '第 ${target + 1} 页无本地缓存，续读不联网，等待显式刷新');
      setNotice('「$q」的上次缓存已失效，无法续读；请下拉刷新或点击搜索重新加载');
    }

    finishLoad();
    // 已读线按存档里的已读线恢复（停留位置可能比读过的位置更靠前）。
    if (resumeAt != null) restoreReadLine(resumeAt);
  }
}
