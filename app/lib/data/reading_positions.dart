import 'local_store.dart';
import '../util/app_log.dart';

/// 一个列表的续读点（阅读存档）。
///
/// 存档里同时记两件**互相独立**的事：
///
/// 1. **停留位置**（[postId] / [index] / [page]）—— 续读的语义就是
///    「记录最后停留的位置」，因此它会随用户的滚动**前后移动**：
///    往前读会前进，往回翻会后退，与这条动态是否已读无关。
///    恢复时按 [postId] → [page] → [index] 的优先级定位。
/// 2. **已读线**（[readPostId] / [readIndex]）—— 只增不减的"读到过哪里"，
///    决定列表里哪些条目显示「已读」。它是纯粹的展示状态，
///    不会因为用户往回翻而退化。
///
/// 早期版本把两者合并成一个只增不减的字段，于是"往回翻到第 5 页再退出"
/// 不会更新续读点（旧位置更靠后，被当成"过期写入"丢弃），与需求不符。
///
/// [cursors] 是每一页的 `last_id` 游标链（`cursors[i]` 是抓第 i 页时要传的
/// `last_id`，第 0 页恒为空串）。游标式分页本身只能向后走，靠这条链才能
/// 在跳到第 N 页之后直接补出第 N-1 页 —— 也就是「续读跳页后仍能上下翻页」。
///
/// [cachedDeepPage] 是「本地缓存覆盖到的最深页号」（0 起，-1 = 旧存档没有
/// 这个字段）。游标链的长度**不等于**缓存页数：最后一页抓取成功且服务端
/// 说还有更多时，链上会多出一条「下一页游标」，但那一页从未被抓取、本地
/// 没有缓存。续读的跳页上限与「缓存是否读完」的判定都要用这个字段，才能
/// 与「上次缓存的所有页」精确对齐。
class ReadingPosition {
  const ReadingPosition({
    required this.postId,
    required this.index,
    required this.updatedAt,
    this.keyword = '',
    this.page = 0,
    this.cursors = const <String>[],
    this.readPostId = '',
    this.readPage = -1,
    this.readOffset = -1,
    this.cachedDeepPage = -1,
  });

  /// 停留位置的条目 id。
  final String postId;

  /// 停留位置的全局序号（在**记录时那个视图**里的扁平序号）。
  ///
  /// 只用于展示（"总第 N 条"）与极端兜底；跨视图定位请用 [page] 与已读线的
  /// (页号, 页内序号)。跳页会丢掉目标页之前的页，扁平序号会整体平移。
  final int index;

  final DateTime updatedAt;

  /// 搜索场景下记录关键词，仅用于提示文案。列表场景为空串。
  final String keyword;

  /// 停留位置所在的页号，0 起。
  final int page;

  /// 各页的 `last_id` 游标链，`cursors[0]` 恒为空串。
  final List<String> cursors;

  /// 已读线的条目 id（可能不在当前已加载的页里）。
  final String readPostId;

  /// 已读线所在页号，-1 表示尚无已读线（旧存档）。
  final int readPage;

  /// 已读线的页内序号（0 起）。
  final int readOffset;

  /// 本地缓存覆盖到的最深页号（0 起），-1 = 未知（旧存档）。
  final int cachedDeepPage;

  /// 能否直接续读：有停留位置即可（第 0 页第 0 条也算）。
  bool get hasStay => postId.isNotEmpty;

  /// 兼容旧存档：没有独立已读线时退回停留位置。
  String get effectiveReadPostId => readPostId.isNotEmpty ? readPostId : postId;

  int get effectiveReadPage => readPage >= 0 ? readPage : page;

  /// 旧存档里 [index] 是扁平序号，当作页内序号用即可覆盖"读到过哪里"的语义
  /// （只会把该页里更靠后的条目也算作已读，不会漏标）。
  int get effectiveReadOffset => readPage >= 0 ? readOffset : index;

  Map<String, dynamic> toJson() => {
        'postId': postId,
        'index': index,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'keyword': keyword,
        'page': page,
        'cursors': cursors,
        'readPostId': readPostId,
        'readPage': readPage,
        'readOffset': readOffset,
        'cachedDeepPage': cachedDeepPage,
      };

  static ReadingPosition? fromJson(Map<String, dynamic> m) {
    final id = m['postId']?.toString() ?? '';
    final idx = m['index'];
    if (id.isEmpty || idx is! num) return null;
    final at = m['updatedAt'];
    final rawCursors = m['cursors'];
    final cursors = <String>[];
    if (rawCursors is List) {
      for (final c in rawCursors) {
        cursors.add(c?.toString() ?? '');
      }
      // 第 0 页的游标按契约必须为空串，存档里被写脏时在此纠正。
      if (cursors.isNotEmpty) cursors[0] = '';
    }
    final page = m['page'];
    final rawReadPage = m['readPage'];
    final rawReadOffset = m['readOffset'];
    final rawDeep = m['cachedDeepPage'];
    return ReadingPosition(
      postId: id,
      index: idx.toInt(),
      updatedAt: at is num
          ? DateTime.fromMillisecondsSinceEpoch(at.toInt())
          : DateTime.now(),
      keyword: m['keyword']?.toString() ?? '',
      page: page is num ? page.toInt() : 0,
      cursors: cursors,
      readPostId: m['readPostId']?.toString() ?? '',
      readPage: rawReadPage is num ? rawReadPage.toInt() : -1,
      readOffset: rawReadOffset is num ? rawReadOffset.toInt() : -1,
      cachedDeepPage: rawDeep is num ? rawDeep.toInt() : -1,
    );
  }

  ReadingPosition copyWith({
    String? postId,
    int? index,
    String? keyword,
    int? page,
    List<String>? cursors,
    String? readPostId,
    int? readPage,
    int? readOffset,
    int? cachedDeepPage,
    DateTime? updatedAt,
  }) =>
      ReadingPosition(
        postId: postId ?? this.postId,
        index: index ?? this.index,
        updatedAt: updatedAt ?? this.updatedAt,
        keyword: keyword ?? this.keyword,
        page: page ?? this.page,
        cursors: cursors ?? this.cursors,
        readPostId: readPostId ?? this.readPostId,
        readPage: readPage ?? this.readPage,
        readOffset: readOffset ?? this.readOffset,
        cachedDeepPage: cachedDeepPage ?? this.cachedDeepPage,
      );
}

/// 续读点存档。
///
/// 以「列表作用域」为键，一个 scope 对应一个续读点。
/// scope 由 [ReadScope] 统一生成，避免各处手写字符串拼错。
class ReadingPositionStore {
  ReadingPositionStore._();

  static final ReadingPositionStore instance = ReadingPositionStore._();

  final Map<String, ReadingPosition> _map = {};

  int get count => _map.length;

  Future<void> load() async {
    _map.clear();
    final m = LocalStore.instance.readMap(LocalStore.keyReadPositions);
    m.forEach((scope, value) {
      if (value is! Map) return;
      final pos = ReadingPosition.fromJson(
        value.map((k, v) => MapEntry(k.toString(), v)),
      );
      if (pos != null) _map[scope] = pos;
    });
  }

  ReadingPosition? get(String scope) => _map[scope];

  /// 记录一次「停留位置」。
  ///
  /// 语义（需求明确）：续读点 = 最后停留的位置，**与已读/未读无关**，
  /// 因此这里的停留位置是**无条件覆盖**的 —— 往回翻到更靠前的位置会直接
  /// 改写存档，而不是像早期版本那样因为「比旧位置靠前」被丢弃。
  ///
  /// 同一时刻顺带维护只增不减的已读线：只有 (页号, 页内序号) 比既有已读线
  /// 更靠后时才抬高它，用户往回翻不会让已读标识退化。
  ///
  /// [cursors] 属于「寻址信息」，只要更完整就吸收 —— 丢了它续读就只能从
  /// 第一页重走一遍。[cachedDeepPage] 同理是寻址信息（缓存覆盖到哪一页），
  /// 这里原样保留既有值；它的更新走 [saveCursors]（与抓取进度天然对齐）。
  ///
  /// 「更完整就吸收」只对**同一血脉**的链成立。血脉判定见 [_lineageSlot]：
  /// 本次上报的链与存档在任一槽位（≥1）分叉，说明这是一次从第 1 页重新
  /// 开始的抓取（同词再次提交 / 下拉刷新 / 缓存过保留期后重抓），旧存档里
  /// 更深的寻址信息与已读线坐标全部作废 —— 此时按本次会话重建，绝不保留
  /// 旧链。否则续读会拿旧游标翻出旧缓存页（第 1 页缓存键固定含空游标、
  /// 必然被新抓覆盖；第 2 页起键里带着旧游标、文件仍在，旧链一指就命中），
  /// 拼出「新第 1 页 + 旧第 2..N 页」的古今混杂存档。
  Future<void> record(
    String scope, {
    required String postId,
    required int index,
    required int page,
    required int offsetInPage,
    String keyword = '',
    List<String>? cursors,
  }) async {
    if (postId.isEmpty) return;
    final old = _map[scope];
    final slot = _lineageSlot(old?.cursors, cursors);
    final continuity = slot < 0;
    final chain = continuity
        ? _mergeCursors(old?.cursors, cursors)
        : _freshChain(cursors);
    final kw = keyword.isEmpty ? (old?.keyword ?? '') : keyword;

    // 已读线只增不减，坐标是 (页号, 页内序号)。血脉变更时按分叉位置归零：
    // 分叉槽位 k 之前的页（0..k-2）内容未变，其上的旧坐标仍有效；第 k-1 页
    // 起内容已换，旧坐标会把新内容的条目错标成「已读」，必须归零重抬。
    var readPostId = old?.readPostId ?? '';
    var readPage = old?.readPage ?? -1;
    var readOffset = old?.readOffset ?? -1;
    if (!continuity && readPage >= slot - 1) {
      readPostId = '';
      readPage = -1;
      readOffset = -1;
    }
    if (readPage < 0 ||
        page > readPage ||
        (page == readPage && offsetInPage > readOffset)) {
      readPostId = postId;
      readPage = page;
      readOffset = offsetInPage;
    }

    if (old != null &&
        old.postId == postId &&
        old.index == index &&
        old.page == page &&
        old.keyword == kw &&
        old.readPostId == readPostId &&
        old.readPage == readPage &&
        old.readOffset == readOffset &&
        _sameCursors(chain, old.cursors)) {
      return; // 没有任何变化，避免滚动过程中反复写盘
    }

    _map[scope] = ReadingPosition(
      postId: postId,
      index: index,
      updatedAt: DateTime.now(),
      keyword: kw,
      page: page,
      cursors: chain,
      readPostId: readPostId,
      readPage: readPage,
      readOffset: readOffset,
      // 缓存深度是寻址信息：同血脉时原样保留（它的更新走 [saveCursors]，
      // 与抓取进度对齐）；血脉变更时置为「未知」，等 saveCursors 用本次
      // 会话的真实深度覆盖。
      cachedDeepPage: continuity ? (old?.cachedDeepPage ?? -1) : -1,
    );
    await _persist();
  }

  /// 只补游标链与缓存深度：每抓到一页调用一次，两者都没变就不落盘。
  ///
  /// 停留位置与已读线原样保留。[cachedDeepPage] 是「本地缓存覆盖到的最深
  /// 页号」（0 起），同血脉下只增不减 —— 续读会话里跳页/翻页只会重新加载
  /// 已在缓存里的页，深度只可能被真正的新抓取推进。
  ///
  /// 血脉变更（见 [_lineageSlot]）时整条旧链与旧深度作废，以本次会话为
  /// 准重建：旧链再长也不能保留，否则续读的跳页与翻页会按旧游标命中
  /// 「旧内容时代」的缓存文件，与新抓的第 1 页拼成混杂存档。已读线坐标
  /// 标在分叉页及更深处的部分一并归零（分叉之前的页内容未变，保留）。
  Future<void> saveCursors(
    String scope,
    List<String> cursors, {
    int? cachedDeepPage,
  }) async {
    final old = _map[scope];
    if (old == null) return;
    final slot = _lineageSlot(old.cursors, cursors);
    final continuity = slot < 0;
    final chain = continuity
        ? _mergeCursors(old.cursors, cursors)
        : _freshChain(cursors);
    final oldDeep = old.cachedDeepPage;
    final newDeep = continuity
        ? ((cachedDeepPage != null && cachedDeepPage > oldDeep)
            ? cachedDeepPage
            : oldDeep)
        : (cachedDeepPage ?? -1);
    // 分叉页（槽 k 分叉 = 第 k-1 页起内容已换）及更深处的旧已读线坐标
    // 标的是旧内容，归零；分叉之前的页内容未变，旧坐标保留。
    final readReset = !continuity && old.readPage >= slot - 1;
    final base = readReset
        ? old.copyWith(readPostId: '', readPage: -1, readOffset: -1)
        : old;
    if (!continuity) {
      log.i(
        LogTag.read,
        '存档血脉变更：旧游标链 ${old.cursors.length} 格作废，'
        '按本次抓取重建为 ${chain.length} 格（深度 ${newDeep < 0 ? '未知' : newDeep + 1} 页）'
        '${readReset ? '，旧已读线已归零' : ''}',
      );
    }
    // 短路条件必须是「内容完全一致」，而不是「长度没变长」：血脉重建的
    // 链往往比旧链短（刚重抓了几页），按长度判断会把它误当无变化丢弃。
    // 已读线被归零时即使链与深度都没变也要落盘。
    if (!readReset &&
        _sameCursors(chain, base.cursors) &&
        newDeep == base.cachedDeepPage) {
      return;
    }
    _map[scope] = base.copyWith(cursors: chain, cachedDeepPage: newDeep);
    await _persist();
  }

  /// 强制写入（用于「从头开始」时把位置归零）。
  Future<void> reset(String scope) async {
    if (_map.remove(scope) == null) return;
    await _persist();
  }

  Future<void> removeScope(String scope) => reset(scope);

  Future<void> clear() async {
    if (_map.isEmpty) return;
    _map.clear();
    await _persist();
  }

  /// 取更长的游标链；长度相同时以新值（[b]）为准。仅限**同血脉**的链。
  static List<String> _mergeCursors(List<String>? a, List<String>? b) {
    final x = a ?? const <String>[];
    final y = b ?? const <String>[];
    final out = List<String>.of(y.length >= x.length ? y : x);
    if (out.isNotEmpty) out[0] = '';
    return out;
  }

  /// 两条游标链的第一个分叉槽位（≥1）；同血脉返回 -1。
  ///
  /// 游标式分页的特性：第 i+1 页的游标由第 i 页的内容生成（末条 id）。
  /// 两条链在槽位 k（≥1）分叉，说明第 k-1 页起服务端内容已经变了（插入
  /// 新帖 / 删帖 / 顺序调整），旧链第 k 格及更深的寻址信息随之全部作废；
  /// 之前的页（0..k-2）请求游标一致、内容未变。任一侧链长不足 2 时（还没
  /// 学到任何「下一页游标」）无法判定，按同血脉（-1）处理，维持原有合并
  /// 逻辑。
  static int _lineageSlot(List<String>? a, List<String>? b) {
    if (a == null || b == null || a.length < 2 || b.length < 2) return -1;
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 1; i < n; i++) {
      if (a[i] != b[i]) return i;
    }
    return -1;
  }

  /// 新血脉链的规范化写入：拷贝一份并把第 0 格强制为空串（契约要求）。
  static List<String> _freshChain(List<String>? chain) =>
      (chain == null || chain.isEmpty)
          ? <String>['']
          : (List<String>.of(chain)..[0] = '');

  static bool _sameCursors(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _persist() => LocalStore.instance.write(
        LocalStore.keyReadPositions,
        _map.map((k, v) => MapEntry(k, v.toJson())),
      );
}

/// 续读点作用域命名。
class ReadScope {
  ReadScope._();

  /// 搜索：按关键词区分（关键词做小写归一，避免大小写产生两份存档）。
  static String search(String keyword) =>
      'search:${keyword.trim().toLowerCase()}';

  /// 收藏夹。
  static const String favourites = 'favourites';

  /// 某个合集内的动态列表。
  static String collection(String id) => 'collection:$id';
}
