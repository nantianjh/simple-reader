import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_exception.dart';
import '../api/models.dart';
import '../api/simple_api.dart';
import '../data/reading_positions.dart';
import '../util/app_log.dart';
import 'load_phase.dart';

/// 一个已加载的分页块。
class ContentPage {
  ContentPage({
    required this.index,
    required this.items,
    required this.hasMore,
  });

  /// 页号，0 起。
  final int index;

  /// 本页内容。取消收藏之类的本地操作会就地增删。
  final List<Post> items;

  /// 本页是否取满（取满说明服务端后面很可能还有下一页）。
  final bool hasMore;
}

/// 分页式内容列表控制器（搜索 / 收藏 / 合集共用）。
///
/// 与「无限瀑布流」的三点区别：
/// * 内容按 [ApiConfig.defaultPerPage]（10）条一页组织，页边界在列表里可见；
/// * 只有滑到当前页末尾才抓下一页、回到当前页开头才抓上一页，两侧首尾相连；
/// * 每一页用 `last_id` 游标独立寻址（[_cursors]），因此可以只加载某一页，
///   也可以在跳到第 N 页之后直接补出第 N-1 / N+1 页 —— 这是「续读记住页数，
///   跳回指定页后仍能正常上下翻页」的前提。游标式分页本身只能单向推进，
///   游标链是补出前一页的唯一办法。
///
/// 两处与"跳页"强相关的约定：
/// 1. **跳页 = 把内容窗口移到目标页**。跳到第 N 页后只保留第 N 页
///    （[jumpToPage] 里的 [_isolatePage]），这样列表顶端、页脚提示、
///    上下补页的方向都与目标页一致。否则「已加载第 1 页 + 跳到第 5 页」
///    会让人回到列表顶端（仍显示第 1 页），表现成"跳页无响应"。
/// 2. 跳页失败也必须把状态收敛回可交互态（不能停在 loading），
///    否则整页会卡在"加载中"，后续跳页入口也一起消失。
abstract class PagedListController extends ChangeNotifier {
  PagedListController({required this.tokenProvider});

  /// 每次请求实时取 token，避免 token 更新后控制器持有旧值。
  final String? Function() tokenProvider;

  /// 续读点作用域，见 [ReadScope]。
  String get scope;

  /// 取一页数据。子类接具体接口。
  Future<PageResult<Post>> fetchPage({
    required String token,
    required String lastId,
    required CacheMode mode,
  });

  /// 收到 401/403 时冒泡到全局状态。
  void Function(String message)? onAuthFailure;

  /// 是否处于「续读」会话：自动翻页只读本地缓存，不发起抓取。
  ///
  /// 存档点语义：上次联网时拉到过哪几页，缓存里就只有哪几页；续读只能读
  /// 这些页，读完即停（页脚「上次缓存内容已阅读完」）。缺缓存不联网兜底。
  bool offlineReading = false;

  /// 自动翻页使用的缓存策略。
  CacheMode get autoMode =>
      offlineReading ? CacheMode.cacheOnly : CacheMode.preferCache;

  /// 从最近的已知页往后补页的步数上限，防止服务端反复返回同一页时死循环。
  static const int _maxWalk = 30;

  // ---------------------------------------------------------- 本地过滤钩子

  /// 抓取到的条目入库前的过滤钩子，默认全部保留。
  ///
  /// 搜索页覆写为「按屏蔽关键词过滤」。注意：翻页游标一律按服务端
  /// 原始页计算（见 [_fetchInto]），被过滤的条目只影响展示、不影响
  /// 游标链，因此过滤不会让翻页错位。
  @protected
  bool shouldKeepPost(Post post) => true;

  int _filteredCount = 0;

  /// 自本次检索 / 刷新起，被 [shouldKeepPost] 剔除的条数（供 UI 提示）。
  int get filteredCount => _filteredCount;

  /// 叠加过滤计数（供子类在关键词变更就地剔除时累加）。
  @protected
  void addFilteredCount(int n) => _filteredCount += n;

  // ------------------------------------------------------------------ 内部

  final Map<int, ContentPage> _pages = <int, ContentPage>{};

  /// `_cursors[i]` = 抓取第 i 页时要传的 `last_id`（第 0 页恒为空串）。
  /// 数组长度即「可寻址的页数」——它永远是 0..n-1 的连续前缀。
  final List<String> _cursors = <String>[''];

  List<ContentPage> _pageList = const <ContentPage>[];
  List<Post> _flat = const <Post>[];

  /// 页号 → 该页首条在 [_flat] 里的序号。
  final Map<int, int> _pageStart = <int, int>{};

  int? _firstPage;
  int? _lastPage;

  LoadPhase _phase = LoadPhase.idle;
  String? _error;
  String? _notice;
  bool _busy = false;
  bool _loadedOnce = false;
  bool _fromCache = false;
  DateTime? _cachedAt;

  /// 已读线的稳定标识与全局坐标。
  ///
  /// 已读线记的是「读到过哪里」，用的是 (页号, 页内序号) 这样的全局坐标，
  /// 而不是扁平序号 —— 跳页/丢页会让扁平序号整体平移，用全局坐标才能在任何
  /// 已加载组合下正确判断"某条是否读过"。
  String _readPostId = '';
  int _readPage = -1;
  int _readOffset = -1;

  /// 「上次浏览到这儿」分界的计算依据：上一次会话性抓取（下拉刷新 /
  /// 新检索）开始**前**已加载的条目 id。快照在内容被替换前拍下，
  /// [reset] 不清它 —— 新内容装进来之后，拿它在新列表里找第一条
  /// 重新出现的旧条目，那就是分界该在的位置。
  Set<String> _prevSessionIds = const <String>{};

  /// 「上次浏览到这儿」应插入的扁平序号（原始值，0 表示分界在首位）。
  int? _cachedBoundary;

  /// 是否已经发起过至少一次内容请求。
  bool ran = false;

  /// 本地缓存覆盖到的最深页号（0 起），-1 = 未知。
  ///
  /// 与 [_cursors] 的长度不是一回事：最后一页抓取成功且服务端说还有更多时，
  /// 游标链会先于抓取长出一格（那格指向的页从未被抓取、本地没有缓存）。
  /// 续读会话的跳页上限（应能跳到「上次缓存的所有页」）与「缓存是否读完」
  /// 的判定都以这个字段为准。只增不减：由真正发生的新抓取推进，续读会话
  /// 里重新加载已在缓存里的页不会使它退缩。
  int _cachedDeepPage = -1;

  // ------------------------------------------------------------------ 只读

  /// 已加载的页，按页号升序。
  List<ContentPage> get pages => _pageList;

  /// 已加载条目的扁平视图（列表直接渲染它）。
  List<Post> get posts => _flat;

  int get itemCount => _flat.length;

  /// 已加载页数。
  int get pageCount => _pageList.length;

  int? get firstPage => _firstPage;
  int? get lastPage => _lastPage;

  /// 是否正在抓某一页。
  bool get busy => _busy;

  LoadPhase get phase => _phase;
  String? get error => _error;
  bool get loadedOnce => _loadedOnce;

  /// 一次性提示（例如"第 3 页不在上次缓存范围内"）。
  String? get notice => _notice;

  bool get fromCache => _fromCache;
  DateTime? get cachedAt => _cachedAt;

  /// 「上次浏览到这儿」应插入的位置（扁平序号）。
  ///
  /// 语义：新抓取的内容在上、上次已浏览的内容在下，分界插在第一条
  /// "上次内容"之前。分界落在首位（说明本次没抓到任何新内容，顶着
  /// 这样一个标没有任何信息量）或没有可标注的分界时返回 null。
  int? get cachedBoundary {
    final b = _cachedBoundary;
    return (b == null || b <= 0) ? null : b;
  }

  /// 已读线所在页，-1 表示当前视图里没有可用的已读线。
  int get readPage => _readPage;

  /// 已加载页的页号，升序。用于日志与排查。
  List<int> get loadedPageIndexes {
    final k = _pages.keys.toList()..sort();
    return k;
  }

  /// 结果为空（请求成功过、但一条都没有）。
  bool get isEmptyResult =>
      ran && _flat.isEmpty && _phase == LoadPhase.ready && !_busy;

  /// 还能往前往后翻吗。判断依据是"目标页的游标是否已知"。
  bool get hasPrevPage {
    final f = _firstPage;
    return f != null && f > 0 && _addressable(f - 1);
  }

  bool get hasNextPage {
    final l = _lastPage;
    return l != null && _addressable(l + 1);
  }

  /// 缓存覆盖到的最深页号（0 起），-1 = 未知（详见 [_cachedDeepPage]）。
  int get cachedDeepPage => _cachedDeepPage;

  /// 「下一页」是否还有本地缓存可翻（续读会话专用口径）。
  ///
  /// 判据：下一页（当前窗口最深页 + 1）游标已知，且没有超出缓存深度。
  /// [hasNextPage] 只看游标链 —— 链上最后一条是「下一页的游标」，
  /// 不代表那一页真的被缓存过；用它判断缓存是否读完会多算一页。
  bool get hasNextCachedPage {
    final l = _lastPage;
    if (l == null) return false;
    final next = l + 1;
    if (!_addressable(next)) return false;
    if (_cachedDeepPage < 0) return true; // 深度未知：退回游标口径
    return next <= _cachedDeepPage;
  }

  /// 已存档的续读点（停留位置）。
  ReadingPosition? get savedPosition => ReadingPositionStore.instance.get(scope);

  bool hasPage(int page) => _pages.containsKey(page);

  /// 某条是否已读。
  ///
  /// 判据是"它落在已读线之前"：
  /// * 页号小于已读线的页 → 整页已读；
  /// * 与已读线同页 → 页内序号不超过已读线即已读；
  /// * 页号更大 → 未读。
  bool isReadAt(int flatIndex) {
    if (flatIndex < 0 || flatIndex >= _flat.length) return false;
    if (_readPage < 0) return false;

    final page = _pageOfFlatIndex(flatIndex);
    if (page == null) return false;
    if (page.index != _readPage) return page.index < _readPage;

    final start = _pageStart[page.index] ?? 0;
    return flatIndex - start <= _readOffset;
  }

  /// 按 id 找当前列表里的全局序号；找不到返回 -1。
  int indexOfPostId(String postId) {
    if (postId.isEmpty) return -1;
    for (var i = 0; i < _flat.length; i++) {
      if (_flat[i].id == postId) return i;
    }
    return -1;
  }

  /// 全局序号 → 所属页号。
  int pageOfItem(int index) {
    final p = _pageOfFlatIndex(index);
    return p?.index ?? _lastPage ?? 0;
  }

  /// 全局序号 → 页内序号。
  int offsetInPage(int index) {
    final p = _pageOfFlatIndex(index);
    if (p == null) return -1;
    return index - (_pageStart[p.index] ?? 0);
  }

  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  // -------------------------------------------------- 供子类使用的状态钩子
  // Dart 只有「库级私有」，子类位于另一个文件时拿不到 `_phase` 这类字段，
  // 因此把子类需要的那几个动作收敛成下面三个受保护方法。

  /// 发起首轮请求前把控制器切到「首屏加载中」。
  @protected
  void beginLoad() {
    _phase = LoadPhase.loadingFirst;
    _error = null;
    notifyListeners();
  }

  /// 首轮请求结束后收敛状态（出错时保留错误态，交给 UI 展示）。
  @protected
  void finishLoad() {
    if (_phase != LoadPhase.error) {
      _phase = LoadPhase.ready;
      _loadedOnce = true;
    }
    notifyListeners();
  }

  /// 设置一次性提示（例如"第 3 页不在上次缓存范围内"）。
  @protected
  void setNotice(String? message) {
    _notice = message;
    notifyListeners();
  }

  /// 把当前已加载的条目记为「上次浏览过的内容」。
  ///
  /// 在一次会话性抓取（下拉刷新 / 新检索）**开始前**调用：快照的就是
  /// 即将被新内容替换掉的部分。新内容装进来后，在新列表里第一次重新
  /// 出现的旧条目上方，就是「上次浏览到这儿」分界该在的位置。
  @protected
  void snapshotPrevSession() {
    _prevSessionIds = <String>{
      for (final p in _flat)
        if (p.id.isNotEmpty) p.id,
    };
    _cachedBoundary = null;
    if (_prevSessionIds.isNotEmpty) {
      log.i(LogTag.page, '记录上次浏览内容 ${_prevSessionIds.length} 条，新抓取后标注分界');
    }
  }

  /// 清掉上次浏览快照（例如进入续读会话：全程读缓存、不产生"新抓取"，
  /// 分界标识没有意义，留着旧快照反而可能在缓存内容里误标）。
  @protected
  void clearPrevSessionSnapshot() {
    _prevSessionIds = const <String>{};
    _cachedBoundary = null;
  }

  /// 清空全部已加载内容与游标（不改变 [ran]）。
  void reset() {
    _pages.clear();
    _cursors
      ..clear()
      ..add('');
    _pageList = const <ContentPage>[];
    _flat = const <Post>[];
    _pageStart.clear();
    _firstPage = null;
    _lastPage = null;
    _phase = LoadPhase.idle;
    _error = null;
    _notice = null;
    _busy = false;
    _loadedOnce = false;
    _fromCache = false;
    _cachedAt = null;
    _readPostId = '';
    _readPage = -1;
    _readOffset = -1;
    // 分界随内容一起清空；_prevSessionIds 保留 —— 下拉刷新正是
    // "先快照再 reset" 的组合，快照必须穿过 reset 活到新内容进来。
    _cachedBoundary = null;
    _filteredCount = 0;
    _cachedDeepPage = -1;
    offlineReading = false;
  }

  /// 吸收续读点里的游标链，使目标页可以直接寻址。
  void adoptCursors(List<String> chain) {
    for (var i = 1; i < chain.length; i++) {
      if (chain[i].isEmpty) break;
      if (i < _cursors.length) continue; // 本地已有更靠前的记录
      if (i > _cursors.length) break; // 链中间断了，后面没法接
      _cursors.add(chain[i]);
    }
  }

  /// 续读进入后恢复「本地缓存覆盖到的最深页号」。
  ///
  /// 必须在 [adoptCursors] 之后调用：旧存档（更新前产生的）没有记录这个
  /// 字段，只能从游标链长度推断 —— 链上最深一格指向的页**可能**没有缓存
  /// （它只是"上一页抓取时服务端说还有更多"的产物），此时向
  /// [probePageCache] 探测一次（只读本地缓存文件，不发请求）来定界。
  /// 新存档直接采用记录值，与真实抓取进度精确对齐。
  Future<void> restoreCachedDeepPage(ReadingPosition pos) async {
    var deep = pos.cachedDeepPage;
    if (deep < 0 && pos.cursors.length >= 2) {
      final top = _cursors.length - 1; // 链上最深可寻址页
      deep = top;
      try {
        final probed = await probePageCache(page: top, lastId: _cursors[top]);
        if (probed == false) deep = top - 1;
      } catch (_) {
        // 探测失败不阻断续读：保守取「链长 - 2」（少算一页只会让
        // 跳页上限与读完提示更保守，不会多发请求）。
        deep = top - 1;
      }
    }
    // 防御：恢复值不能超出当前游标链的可寻址范围。
    if (deep > _cursors.length - 1) deep = _cursors.length - 1;
    if (deep > _cachedDeepPage) _cachedDeepPage = deep;
    log.i(
      LogTag.page,
      '续读恢复缓存深度：最深第 ${_cachedDeepPage + 1} 页'
      '（游标链 ${_cursors.length} 格，存档记录 ${pos.cachedDeepPage < 0 ? '无' : pos.cachedDeepPage + 1}）',
    );
  }

  /// 探测某页的本地缓存是否存在（只读缓存文件，**不发任何请求**）。
  ///
  /// 子类按自己的签名规则实现；无法探测（或不支持）时返回 null，
  /// [restoreCachedDeepPage] 会退回保守推断。参数给的是页号与该页的
  /// `last_id` 游标 —— 游标链是库级私有字段，子类拿不到，由这里传入。
  @protected
  Future<bool?> probePageCache({required int page, required String lastId}) =>
      Future<bool?>.value();

  // ------------------------------------------------------------------ 加载

  /// 加载第 [page] 页。已加载则直接返回 true。
  ///
  /// [mode] 缺省用 [autoMode]。
  Future<bool> loadPage(int page, {CacheMode? mode}) async {
    if (page < 0) return false;
    if (_pages.containsKey(page)) return true;
    if (_busy) {
      log.d(LogTag.page, 'loadPage(${page + 1}) 跳过：控制器正忙');
      return false;
    }

    final m = mode ?? autoMode;
    _busy = true;
    _error = null;
    notifyListeners();

    final sw = Stopwatch()..start();
    var ok = false;
    try {
      // 游标未知时从最近的已知页往后逐页补齐（存档里没有游标链时的兜底）。
      var guard = 0;
      while (!_addressable(page) && guard < _maxWalk) {
        final next = _cursors.length;
        if (next > page) break;
        final before = _cursors.length;
        log.d(LogTag.page, '游标未知，先补齐第 ${next + 1} 页');
        final r = await _fetchInto(next, m);
        if (r != _FetchResult.ok || _cursors.length == before) break;
        guard++;
      }

      if (!_addressable(page)) {
        if (_phase != LoadPhase.error) {
          _phase = LoadPhase.error;
          _error = '无法定位到第 ${page + 1} 页：本地缺少该页游标，也没能从前面补齐。';
        }
        log.w(LogTag.page, '第 ${page + 1} 页不可寻址（游标链 ${_cursors.length} 条）');
        return false;
      }

      final r = await _fetchInto(page, m);
      if (r == _FetchResult.ok) {
        _loadedOnce = true;
        _phase = LoadPhase.ready;
        ok = true;
        log.d(
          LogTag.page,
          '加载第 ${page + 1} 页成功：${_pages[page]?.items.length ?? 0} 条'
          '，来源=${m.name}${AppLog.ms(sw)}',
        );
      } else if (r == _FetchResult.miss) {
        // 只读缓存未命中：不改 phase，交由调用方决定是否联网。
        log.i(LogTag.page, '第 ${page + 1} 页本地无缓存（${m.name}）${AppLog.ms(sw)}');
        ok = false;
      } else {
        log.w(LogTag.page,
            '加载第 ${page + 1} 页失败：${_error ?? '未知原因'}${AppLog.ms(sw)}');
      }
      return ok;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 抓下一页（当前页末尾再往上滑）。
  Future<bool> nextPage() async {
    final l = _lastPage;
    if (l == null || !hasNextPage) return false;
    // 续读会话里缓存已经读完：不再尝试抓取（cacheOnly 必然未命中），
    // 页脚与自动补页都已切换到「缓存读完」口径，这里短路省一次读盘。
    if (offlineReading && !hasNextCachedPage) return false;
    return loadPage(l + 1);
  }

  /// 抓上一页（当前页开头再往下滑）。
  Future<bool> prevPage() async {
    final f = _firstPage;
    if (f == null || f <= 0) return false;
    return loadPage(f - 1);
  }

  /// 跳到指定页（「跳至指定页」与「续读」共用）。
  ///
  /// 三个关键点：
  /// 1. 先等控制器空闲 —— 跳页是用户显式动作，不能因为后台正在补页就静默失败；
  /// 2. 成功后把内容窗口收敛到目标页 —— 目标页成为列表的唯一页面，
  ///    跳页才"看得见"（见 [_isolatePage]）；
  /// 3. 无论成败都把状态收敛回可交互态，绝不留下永久的 loading。
  ///
  /// [mode] 缺省用 [autoMode]。存档点语义：续读会话（cacheOnly）目标页
  /// 缺缓存时**不联网兜底**，如实提示后停在当前页；联网模式（preferCache）
  /// 缺缓存直接抓取，属正常浏览路径。
  Future<bool> jumpToPage(int page, {CacheMode? mode}) async {
    if (page < 0) return false;
    final m = mode ?? autoMode;

    _phase = LoadPhase.loadingFirst;
    _notice = null;
    notifyListeners();

    log.i(
      LogTag.page,
      '跳页请求 → 第 ${page + 1} 页（$m）；当前已加载：'
      '${loadedPageIndexes.map((i) => i + 1).join('、')}',
    );

    await _waitIdle();

    var ok = await loadPage(page, mode: m);
    // 存档点语义：续读会话缺缓存不联网兜底 —— 如实提示后停在当前页，
    // 由下方失败分支把状态收敛回可交互态（绝不留在 loading）。
    if (!ok && m == CacheMode.cacheOnly && _phase == LoadPhase.loadingFirst) {
      setNotice('第 ${page + 1} 页不在上次缓存范围内（缓存可能已过期），'
          '请下拉刷新或重新搜索加载');
      log.i(LogTag.page, '第 ${page + 1} 页无本地缓存，续读会话不联网兜底');
    }

    if (ok) {
      _isolatePage(page);
      _loadedOnce = true;
      _phase = LoadPhase.ready;
      log.i(
        LogTag.page,
        '跳页成功 → 第 ${page + 1} 页；已加载：'
        '${_pageList.map((p) => '${p.index + 1}(${p.items.length}条)').join('、')}',
      );
    } else {
      if (_phase == LoadPhase.loadingFirst) _phase = LoadPhase.ready;
      _error ??= '第 ${page + 1} 页打不开。';
      log.w(
        LogTag.page,
        '跳页失败 → 第 ${page + 1} 页：$_error；已加载：'
        '${loadedPageIndexes.map((i) => i + 1).join('、')}',
      );
    }
    notifyListeners();
    return ok;
  }

  /// 下拉刷新：丢掉已加载的页，从第一页强制走网络。
  Future<void> refresh({CacheMode mode = CacheMode.networkFirst}) async {
    log.i(LogTag.page, '刷新：清空已加载内容并重抓第 1 页');
    // 刷新前的内容就是"上次浏览的"——快照必须在 reset 之前拍。
    snapshotPrevSession();
    reset();
    ran = true;
    _phase = LoadPhase.loadingFirst;
    notifyListeners();
    final ok = await loadPage(0, mode: mode);
    if (_phase != LoadPhase.error) {
      // 刷新后要么有内容、要么就是真的空，两种情况都算加载完成。
      _phase = LoadPhase.ready;
      _loadedOnce = _loadedOnce || ok;
    }
    notifyListeners();
  }

  Future<void> retry() async {
    if (_flat.isEmpty) {
      _phase = LoadPhase.loadingFirst;
      notifyListeners();
      await loadPage(0, mode: CacheMode.networkFirst);
      if (_phase != LoadPhase.error) _phase = LoadPhase.ready;
      notifyListeners();
      return;
    }
    if (hasNextPage) {
      await nextPage();
    } else {
      await loadPage(_lastPage ?? 0, mode: CacheMode.networkFirst);
    }
  }

  Future<_FetchResult> _fetchInto(int page, CacheMode mode) async {
    final token = tokenProvider();
    if (token == null || token.isEmpty) {
      _phase = LoadPhase.error;
      _error = '尚未配置 token';
      log.w(LogTag.page, '第 ${page + 1} 页取数中止：尚未配置 token');
      return _FetchResult.fail;
    }

    final sw = Stopwatch()..start();
    try {
      final res =
          await fetchPage(token: token, lastId: _cursors[page], mode: mode);
      if (res.cacheMiss) return _FetchResult.miss;

      // 本地过滤（屏蔽关键词等）在入库前进行；翻页游标按服务端原始页
      // 计算，不跟随过滤结果，否则"被过滤条目占了游标位"会让翻页错位。
      final rawItems = res.items;
      final kept = <Post>[];
      var blocked = 0;
      for (final p in rawItems) {
        if (shouldKeepPost(p)) {
          kept.add(p);
        } else {
          blocked++;
        }
      }
      if (blocked > 0) {
        _filteredCount += blocked;
        log.i(LogTag.page,
            '第 ${page + 1} 页按本地规则过滤掉 $blocked 条（累计 $_filteredCount）');
      }

      _pages[page] = ContentPage(
        index: page,
        items: kept,
        hasMore: res.hasMore,
      );

      final next = res.nextCursor;
      if (res.hasMore) {
        // 服务端没给出可用的行 id 时，退回用解析后的最后一条 id 作游标：
        // 游标语义本就是"上一页最后一条的 id"，少一次"翻不动页"的死角。
        final fallback = rawItems.isEmpty ? null : rawItems.last.id;
        final cursor = (next != null && next.isNotEmpty) ? next : fallback;
        if (cursor != null && cursor.isNotEmpty) _learnCursor(page + 1, cursor);
      }

      if (_firstPage == null || page < _firstPage!) _firstPage = page;
      if (_lastPage == null || page > _lastPage!) _lastPage = page;
      // 真正抓到手的页才推进缓存深度（跳页后窗口里只有目标页，
      // 不能用它缩小既有深度 —— 深度只增不减）。
      if (page > _cachedDeepPage) _cachedDeepPage = page;

      _fromCache = res.fromCache;
      _cachedAt = res.cachedAt;
      _error = null;
      _rebuild();

      log.d(
        LogTag.page,
        '取到第 ${page + 1} 页：${res.items.length} 条'
        '，hasMore=${res.hasMore}，来源=${res.fromCache ? '本地缓存' : '网络'}'
        '${AppLog.ms(sw)}',
      );

      // 游标链落盘：续读跳页靠它，缺链会让跳页退化成从第一页重走。
      // 缓存深度一并落盘 —— 续读的跳页上限与「读完」判定都靠它。
      unawaited(
        ReadingPositionStore.instance.saveCursors(
          scope,
          List<String>.of(_cursors),
          cachedDeepPage: _cachedDeepPage,
        ),
      );
      return _FetchResult.ok;
    } on ApiException catch (e) {
      _phase = LoadPhase.error;
      _error = e.message;
      log.e(LogTag.page, '第 ${page + 1} 页取数失败：${e.message}');
      if (e.requiresReauth) onAuthFailure?.call(e.message);
    } catch (e, st) {
      _phase = LoadPhase.error;
      _error = '未知错误：$e';
      log.exception(LogTag.page, '第 ${page + 1} 页取数异常', e, st);
    }
    return _FetchResult.fail;
  }

  /// 等当前正在进行的请求结束（跳页前调用），最多等 [timeout]。
  Future<bool> _waitIdle({Duration timeout = const Duration(seconds: 4)}) async {
    if (!_busy) return true;
    log.d(LogTag.page, '控制器正忙，等待其结束…');
    final deadline = DateTime.now().add(timeout);
    while (_busy && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    return !_busy;
  }

  /// 跳页后把内容窗口收敛到目标页：只留目标页，其余已加载的页都丢掉。
  ///
  /// 为什么必须丢：
  /// * 列表是按页号升序拼接的，若更靠前的页还在列表里，「滚到列表顶端」
  ///   看到的就是那一页 —— 用户会以为跳页没生效（"跳页无响应"）；
  /// * 若更靠后的页还留着，列表里会出现「第 1 页 → 第 18 页」这种断层，
  ///   而且页脚提示的"下一页"会指向第 19 页，与当前所在的第 1 页完全脱节。
  ///
  /// 丢掉不等于丢失：这些页随时能用缓存在滚动时重新补出来（[prevPage] /
  /// [nextPage]），只是重新读一次本地缓存。已读线用的是 (页号, 页内序号)
  /// 这样的全局坐标，不依赖"哪几页被加载过"，因此丢页不会让已读标识错乱。
  void _isolatePage(int page) {
    final dropped = _pages.keys.where((k) => k != page).toList();
    _firstPage = page;
    _lastPage = page;
    if (dropped.isEmpty) return;
    for (final k in dropped) {
      _pages.remove(k);
    }
    _rebuild();
    log.d(
      LogTag.page,
      '跳页窗口收敛：只保留第 ${page + 1} 页，'
      '丢弃 ${dropped.map((i) => i + 1).join('、')}',
    );
  }

  // -------------------------------------------------------------- 本地变更

  /// 本地同步点赞态，避免整页刷新。
  void applyVote(String postId, bool voted) {
    for (final p in _flat) {
      if (p.id == postId) {
        p.isVoted = voted;
        notifyListeners();
        return;
      }
    }
  }

  /// 本地同步收藏态，避免整页刷新。
  void applyFavourite(String postId, bool faved) {
    for (final p in _flat) {
      if (p.id == postId) {
        p.isFavourited = faved;
        notifyListeners();
        return;
      }
    }
  }

  /// 就地移除一条（取消收藏后立刻反映到列表）。
  void removePost(String postId) {
    for (final p in _pageList) {
      final i = p.items.indexWhere((e) => e.id == postId);
      if (i >= 0) {
        p.items.removeAt(i);
        _rebuild();
        notifyListeners();
        return;
      }
    }
  }

  /// 就地移除所有满足条件的条目并重建列表，返回移除条数。
  ///
  /// 屏蔽关键词在会话中途变化时，用它把新规则立即套到已加载的内容上。
  /// 被移除的条目本地不再保留：删除关键词后要看到它们，需下拉刷新重抓。
  @protected
  int removePostsWhere(bool Function(Post) test) {
    var removed = 0;
    for (final p in _pages.values) {
      final before = p.items.length;
      p.items.removeWhere(test);
      removed += before - p.items.length;
    }
    if (removed > 0) {
      _rebuild();
      notifyListeners();
    }
    return removed;
  }

  /// 记录「最后停留的位置」。
  ///
  /// 语义来自需求：续读点就是最后停在哪，**与这条动态已读还是未读无关**，
  /// 因此这里无条件写入存档（往回翻会直接改写续读点）。已读线由存档内部
  /// 单独维护，只增不减，往回翻不会让已读标识退化。
  ///
  /// 同一位置重复调用是安全的（存档内部会比对，无变化不落盘）。
  Future<void> notePosition(int index) async {
    if (index < 0 || index >= _flat.length) return;
    final post = _flat[index];
    final page = pageOfItem(index);
    final offset = offsetInPage(index);

    // 已读线随手抬高（只增不减）：同一页比页内序号，跨页比页号。
    if (_readPage < 0 ||
        page > _readPage ||
        (page == _readPage && offset > _readOffset)) {
      _readPage = page;
      _readOffset = offset;
      _readPostId = post.id;
    }

    await ReadingPositionStore.instance.record(
      scope,
      postId: post.id,
      index: index,
      page: page,
      offsetInPage: offset,
      cursors: List<String>.of(_cursors),
    );
    notifyListeners();
  }

  /// 续读进入后把「已读线」恢复到存档里的位置。
  ///
  /// 与旧实现的区别：旧实现用**停留位置**当已读线，而停留位置现在可能
  /// 比"读到过哪里"更靠前（用户往回翻过），那会把读过的内容重新标成未读。
  /// 这里优先用存档里的已读线。
  void restoreReadLine(ReadingPosition pos) {
    _readPostId = pos.effectiveReadPostId;
    _readPage = pos.readPage;
    _readOffset = pos.readOffset;
    if (_readPage < 0) {
      // 旧存档没有独立的已读线：退回停留位置，与旧行为一致。
      _readPage = pos.page;
      _readOffset = pos.index;
    }
    log.i(
      LogTag.read,
      '已读线恢复：page=${_readPage + 1} offset=$_readOffset '
      '（当前视图是否命中：${indexOfPostId(_readPostId) >= 0}）',
    );
    notifyListeners();
  }

  // ------------------------------------------------------------------ 内部

  bool _addressable(int page) => page >= 0 && page < _cursors.length;

  /// 只接连续的下一页游标，保证 `_cursors` 永远是完整前缀。
  void _learnCursor(int page, String cursor) {
    if (cursor.isEmpty) return;
    if (page != _cursors.length) return;
    _cursors.add(cursor);
  }

  ContentPage? _pageOfFlatIndex(int index) {
    for (final p in _pageList) {
      final start = _pageStart[p.index] ?? 0;
      if (index >= start && index < start + p.items.length) return p;
    }
    return null;
  }

  void _rebuild() {
    final keys = _pages.keys.toList()..sort();
    final list = <ContentPage>[];
    final flat = <Post>[];
    final seen = <String>{};
    var dropped = 0;
    _pageStart.clear();
    for (final k in keys) {
      final p = _pages[k]!;
      // 服务端插入新内容会让页边界整体后移，相邻两页之间可能出现同一条。
      // 同一条渲染两次会撞上重复 GlobalKey，这里就地去掉重复项。
      p.items.removeWhere((post) {
        final dup = post.id.isEmpty || !seen.add(post.id);
        if (dup) dropped++;
        return dup;
      });
      _pageStart[p.index] = flat.length;
      list.add(p);
      flat.addAll(p.items);
    }
    // 去重会让某页的条目数变少、列表整体变矮，是"无操作也跳一下"的候选成因，
    // 因此出现时必须留痕（此前完全静默）。
    if (dropped > 0) {
      log.d(
        LogTag.page,
        '列表重建：去掉 $dropped 条跨页重复条目（当前 ${flat.length} 条）',
      );
    }
    _pageList = list;
    _flat = flat;
    _recomputeCachedBoundary();
  }

  /// 在当前列表里定位「上次浏览到这儿」分界：第一条属于上次浏览内容
  /// 的条目。每次重建后重算 —— 向上补页 / 跳页丢页 / 跨页去重都会让
  /// 扁平序号平移，只有重算才能让分界始终跟着那第一条旧内容走。
  void _recomputeCachedBoundary() {
    _cachedBoundary = null;
    if (_prevSessionIds.isEmpty) return;
    for (var i = 0; i < _flat.length; i++) {
      if (_prevSessionIds.contains(_flat[i].id)) {
        _cachedBoundary = i;
        log.d(LogTag.page, '「上次浏览到这儿」分界定位在第 ${i + 1} 条');
        return;
      }
    }
  }
}

enum _FetchResult { ok, miss, fail }
