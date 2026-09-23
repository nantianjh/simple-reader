import 'package:flutter_test/flutter_test.dart';
import 'package:simple_reader/api/models.dart';
import 'package:simple_reader/api/simple_api.dart';
import 'package:simple_reader/data/reading_positions.dart';
import 'package:simple_reader/state/load_phase.dart';
import 'package:simple_reader/state/paged_list.dart';

/// 复现「缓存模式（续读）下跳页」的行为。
///
/// 场景：一次会话读满 19 页（存档在第 19 页），重启后进入续读模式
/// （只读本地缓存），依次跳到 17、18 页，再跳到第 1 页，观察后续跳页是否还能成功。
///
/// 这里用一个自带"服务端 + 缓存"的假控制器，真实度对齐 [ContentCache] 的语义：
/// * 联网请求会把结果写进 store；
/// * `cacheOnly` 只读 store，未命中返回 `cacheMiss`；
/// * 游标 = 上一页最后一条的 id。
class FakePagedController extends PagedListController {
  FakePagedController({
    required super.tokenProvider,
    required this.store,
    this.universeSize = 200,
    this.scopeName = 'test:fake',
  });

  /// 共享的"本地缓存"（cursor -> rows）。
  final Map<String, List<Map<String, dynamic>>> store;

  final int universeSize;

  /// 续读点作用域（每个用例用独立 scope，避免用例之间互相污染）。
  final String scopeName;

  /// 记录每一次请求，便于断言"是否真的又发了请求"。
  final List<String> log = <String>[];

  @override
  String get scope => scopeName;

  String idAt(int i) => 'p$i';

  /// 模拟服务端：cursor 为空返回头 10 条，否则返回 cursor 之后的 10 条。
  List<Map<String, dynamic>> _server(String cursor) {
    var start = 0;
    if (cursor.isNotEmpty) {
      final n = int.tryParse(cursor.substring(1)) ?? 0;
      start = n + 1;
    }
    final out = <Map<String, dynamic>>[];
    for (var i = start; i < start + 10 && i < universeSize; i++) {
      out.add({'id': idAt(i), 'content': 'post $i'});
    }
    return out;
  }

  @override
  Future<PageResult<Post>> fetchPage({
    required String token,
    required String lastId,
    required CacheMode mode,
  }) async {
    log.add('${mode.name}|$lastId');
    if (mode == CacheMode.cacheOnly) {
      final rows = store[lastId];
      if (rows == null) return PageResult.miss<Post>();
      return _page(rows, fromCache: true);
    }
    final rows = _server(lastId);
    store[lastId] = rows;
    return _page(rows, fromCache: false);
  }

  PageResult<Post> _page(List<Map<String, dynamic>> rows, {required bool fromCache}) {
    final posts = rows.map(Post.fromJson).where((p) => p.id.isNotEmpty).toList();
    final hasMore = posts.length >= 10;
    return PageResult<Post>(
      items: posts,
      nextCursor: hasMore ? posts.last.id : null,
      hasMore: hasMore,
      fromCache: fromCache,
    );
  }
}

String describe(PagedListController c) {
  final pages = c.pages.map((p) => '${p.index}(${p.items.length})').join(',');
  return 'pages=[$pages] flat=${c.posts.length} '
      'first=${c.firstPage} last=${c.lastPage} '
      'busy=${c.busy} phase=${c.phase} err=${c.error}';
}

void main() {
  // 平台通道的 MethodChannel 需要绑定；本机没有原生实现时会抛
  // MissingPluginException，NativeBridge 已吞并并降级为"本次不落盘"。
  TestWidgetsFlutterBinding.ensureInitialized();

  test('续读（cacheOnly）下的跳页序列', () async {
    final store = <String, List<Map<String, dynamic>>>{};

    // ---------- 会话 1：联网读满 19 页（0..18），存档落在第 19 页 ----------
    final s1 = FakePagedController(tokenProvider: () => 't', store: store);
    s1.ran = true;
    for (var i = 0; i < 19; i++) {
      await s1.loadPage(i, mode: CacheMode.networkFirst);
    }
    // ignore: avoid_print
    print('会话1 → ${describe(s1)}');
    await s1.notePosition(s1.posts.length - 1);

    final pos = ReadingPositionStore.instance.get(s1.scope);
    expect(pos, isNotNull);
    // ignore: avoid_print
    print('存档 → page=${pos!.page} index=${pos.index} '
        'chainLen=${pos.cursors.length}');

    // ---------- 会话 2：重启后走续读（只读缓存） ----------
    final s2 = FakePagedController(tokenProvider: () => 't', store: store);
    s2.ran = true;
    s2.offlineReading = true;
    s2.adoptCursors(pos.cursors);

    final j17 = await s2.jumpToPage(16);
    // ignore: avoid_print
    print('跳到 17 页 → $j17 | ${describe(s2)}');
    final j18 = await s2.jumpToPage(17);
    // ignore: avoid_print
    print('跳到 18 页 → $j18 | ${describe(s2)}');
    final j1 = await s2.jumpToPage(0);
    // ignore: avoid_print
    print('跳到 1 页  → $j1 | ${describe(s2)}');
    final j5 = await s2.jumpToPage(4);
    // ignore: avoid_print
    print('跳到 5 页  → $j5 | ${describe(s2)}');
    final j9 = await s2.jumpToPage(8);
    // ignore: avoid_print
    print('跳到 9 页  → $j9 | ${describe(s2)}');
    // ignore: avoid_print
    print('请求序列 → ${s2.log.join(' ; ')}');

    expect(j17, isTrue);
    expect(j18, isTrue);
    expect(j1, isTrue);
    expect(j5, isTrue, reason: '跳到第 1 页之后，再跳第 5 页不应失联');
    expect(j9, isTrue, reason: '跳到第 1 页之后，再跳第 9 页不应失联');

    // 跳页后列表顶端必须就是目标页 —— 用户点「跳转」之后，
    // 界面把视口拉回列表顶端，若顶端还留着更靠前的页，就表现为"跳页无响应"。
    expect(s2.firstPage, 8, reason: '最后一次跳到第 9 页，顶端应是第 9 页');
    expect(s2.posts.first.id, 'p80', reason: '顶端首条应是第 9 页的首条');
  });

  test('跳页目标缺缓存时不联网兜底：如实提示并收敛状态（存档点语义）', () async {
    final store = <String, List<Map<String, dynamic>>>{};
    final c = FakePagedController(tokenProvider: () => 't', store: store);
    c.ran = true;
    c.offlineReading = true;
    c.adoptCursors(<String>['', 'p9', 'p19', 'p29', 'p39']);

    // 第 3 页（index 2）本地没有缓存 → 不联网兜底，如实提示，不能卡在 loading。
    final ok = await c.jumpToPage(2);
    expect(ok, isFalse);
    expect(c.phase, LoadPhase.ready, reason: '跳页结束后不能停在 loading');
    expect(c.posts, isEmpty, reason: '存档点语义：不得联网补抓存档之外的页');
    expect(
      c.log.where((e) => e.startsWith('networkFirst')),
      isEmpty,
      reason: 'cacheOnly 未命中不允许发出任何联网请求',
    );
    expect(c.notice, contains('不在上次缓存范围内'));
  });

  test('续读点 = 最后停留位置（可回退），已读线只增不减', () async {
    final c = FakePagedController(
      tokenProvider: () => 't',
      store: <String, List<Map<String, dynamic>>>{},
      scopeName: 'test:stay',
    );
    c.ran = true;
    for (var i = 0; i < 3; i++) {
      await c.loadPage(i, mode: CacheMode.networkFirst);
    }

    // 停在第 3 页最后一条（扁平序号 25 = 第 3 页第 6 条）
    await c.notePosition(25);
    var pos = ReadingPositionStore.instance.get('test:stay')!;
    expect(pos.page, 2);
    expect(pos.index, 25);
    expect(pos.readPage, 2);
    expect(pos.readOffset, 5);
    expect(c.isReadAt(25), isTrue);
    expect(c.isReadAt(26), isFalse);

    // 往回翻到第 1 页第 3 条：停留位置必须跟着回退
    await c.notePosition(2);
    pos = ReadingPositionStore.instance.get('test:stay')!;
    expect(pos.page, 0, reason: '续读点是"最后停留位置"，往回翻要跟着更新');
    expect(pos.index, 2);
    expect(pos.readPage, 2, reason: '已读线只增不减');
    expect(pos.readOffset, 5);

    // 已读线不退化：之前读过的位置仍然算已读
    expect(c.isReadAt(25), isTrue, reason: '往回翻不应把读过的内容重新标成未读');
    expect(c.isReadAt(5), isTrue, reason: '第 1 页整页都在已读线之前');
  });
}
