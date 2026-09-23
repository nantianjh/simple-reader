import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_reader/api/models.dart';
import 'package:simple_reader/api/simple_api.dart';
import 'package:simple_reader/state/paged_list.dart';
import 'package:simple_reader/ui/widgets/paged_post_list.dart';
import 'package:simple_reader/ui/widgets/read_tracker.dart';

/// 「跳至指定页」入口的 UI 规则（v1.8.7 需求）：
/// * 只能在**已加载**的页之间跳：只加载了 1 页时入口整体隐藏；
/// * 每一页的页首（页眉）与页尾各有一个入口；
/// * 跳转后列表只保留目标页，入口随之再次隐藏。
///
/// 测试基建说明：
/// * 条目统一 300px 高，内容远高于 1.5 屏 → [PagedPostList] 的自动补页
///   （_autoFill）不会在中途插页（除"高视口"用例外，页数完全由用例控制）；
/// * 假接口对超出 [availablePages] 的页返回 cacheMiss → 不产生空页；
/// * ListView 惰性构建，远处的行 find 不到 —— 需要"整页清点"的用例用
///   高视口让全部行一次性构建；
/// * 结尾 pump 推进假时钟，冲掉 AppLog 900ms 落盘定时器与 260ms 续读
///   采样防抖，否则触发 "Timer is still pending" 不变量。
class _FakeController extends PagedListController {
  _FakeController({
    required super.tokenProvider,
    required this.store,
    this.availablePages = 3,
  });

  final Map<String, List<Map<String, dynamic>>> store;

  /// 服务端总页数。超出页码返回 cacheMiss（loadPage 不会把它收进列表）。
  final int availablePages;

  @override
  String get scope => 'test:jump-entry';

  @override
  Future<PageResult<Post>> fetchPage({
    required String token,
    required String lastId,
    required CacheMode mode,
  }) async {
    var start = 0;
    if (lastId.isNotEmpty) {
      start = (int.tryParse(lastId.substring(1)) ?? -1) + 1;
    }
    final pageIdx = start ~/ 10;
    if (pageIdx >= availablePages) return PageResult.miss<Post>();
    final rows = <Map<String, dynamic>>[
      for (var i = start; i < start + 10; i++)
        {'id': 'p$i', 'content': 'post $i'},
    ];
    store[lastId] = rows;
    final hasMore = pageIdx < availablePages - 1;
    final posts = rows.map(Post.fromJson).where((p) => p.id.isNotEmpty).toList();
    return PageResult<Post>(
      items: posts,
      nextCursor: hasMore ? posts.last.id : null,
      hasMore: hasMore,
      fromCache: false,
    );
  }
}

enum _Viewport { phone, tall }

Future<ScrollController> _pumpList(WidgetTester tester, _FakeController c,
    [_Viewport viewport = _Viewport.phone]) async {
  // phone：360×800 逻辑分辨率（与真机接近）；tall：一屏装下全部行，
  // 供"清点入口个数"用例使用（内容不足 1.5 屏也不会触发自动补页，
  // 因为假接口已没有更多页）。
  switch (viewport) {
    case _Viewport.phone:
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
    case _Viewport.tall:
      tester.view.physicalSize = const Size(1080, 24000);
      tester.view.devicePixelRatio = 1.0;
  }
  addTearDown(tester.view.reset);

  final scroll = ScrollController();
  final tracker = ItemVisibilityTracker(scroll);
  // 真实页面（搜索/收藏/合集）都用 AnimatedBuilder 包住 PagedPostList，
  // 控制器变化驱动列表重建 —— 测试必须一致，否则跳页后列表永远停在旧数据。
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AnimatedBuilder(
          animation: c,
          builder: (context, _) => PagedPostList(
            controller: c,
            scrollController: scroll,
            tracker: tracker,
            enableRefresh: false,
            itemBuilder: (context, post, index) => SizedBox(
              height: 300,
              child: Text(post.id, textDirection: TextDirection.ltr),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return scroll;
}

/// 冲掉测试期间排下的定时器（AppLog 落盘 900ms / 续读采样 260ms 防抖）。
Future<void> _flushTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  testWidgets('只有 1 页时跳页入口整体隐藏', (tester) async {
    final c = _FakeController(
      tokenProvider: () => 't',
      store: <String, List<Map<String, dynamic>>>{},
      availablePages: 2,
    );
    c.ran = true;
    await c.loadPage(0, mode: CacheMode.networkFirst);
    await _pumpList(tester, c);

    expect(c.pageCount, 1);
    expect(find.text('第 1 页'), findsOneWidget);
    expect(find.text('跳至指定页'), findsNothing,
        reason: '只拉取了第一页时不显示跳页入口');
    expect(find.byIcon(Icons.unfold_more_rounded), findsNothing,
        reason: '页眉在无处可跳时应退化为纯文本');

    await _flushTimers(tester);
  });

  testWidgets('加载两页后：每页页首与页尾各一个跳页入口', (tester) async {
    final c = _FakeController(
      tokenProvider: () => 't',
      store: <String, List<Map<String, dynamic>>>{},
      availablePages: 2,
    );
    c.ran = true;
    await c.loadPage(0, mode: CacheMode.networkFirst);
    await c.loadPage(1, mode: CacheMode.networkFirst);
    // 高视口：全部行一次构建，可以精确清点。
    await _pumpList(tester, c, _Viewport.tall);

    expect(c.pageCount, 2);
    expect(find.text('跳至指定页'), findsNWidgets(2),
        reason: '每页页尾各一个跳页入口');
    expect(find.byIcon(Icons.unfold_more_rounded), findsNWidgets(2),
        reason: '每页页首的页眉各带一个跳页入口箭头');
    expect(find.text('第 1 页'), findsOneWidget);
    expect(find.text('第 2 页'), findsOneWidget);
    expect(find.text('已是最后一页 · 共 20 条'), findsOneWidget);

    await _flushTimers(tester);
  });

  testWidgets('范围内跳转成功，列表只留目标页且入口随之隐藏', (tester) async {
    final c = _FakeController(
      tokenProvider: () => 't',
      store: <String, List<Map<String, dynamic>>>{},
      availablePages: 2,
    );
    c.ran = true;
    await c.loadPage(0, mode: CacheMode.networkFirst);
    await c.loadPage(1, mode: CacheMode.networkFirst);
    await _pumpList(tester, c);

    // 滚到第 1 页页尾，打开跳页弹窗。
    await tester.scrollUntilVisible(
      find.text('跳至指定页'),
      800,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('跳至指定页'));
    await tester.pumpAndSettle();
    expect(find.text('页号（1–2）'), findsOneWidget);

    // 超出范围的输入必须被拦下。
    await tester.enterText(find.byType(TextField), '5');
    await tester.tap(find.text('跳转'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 1–2 之间的页号'), findsOneWidget,
        reason: '跳页范围必须限定在已加载的页');

    // 合法输入：跳到第 2 页。
    await tester.enterText(find.byType(TextField), '2');
    await tester.tap(find.text('跳转'));
    await tester.pumpAndSettle();

    // 落地在第 2 页：视口顶端是第 2 页的首条 p10。
    // 回顶动作不得触发"补上一页"（跳页落地保护），否则第 1 页会被垫回
    // 视口上方，看起来就像跳页没生效。
    expect(find.text('p10'), findsOneWidget, reason: '视口应停在第 2 页页首');
    expect(find.text('p0'), findsNothing,
        reason: '第 1 页的内容不应出现在视口内');
    expect(find.text('第 2 页'), findsOneWidget,
        reason: '当前页页眉仍是第 2 页');

    await _flushTimers(tester);
  });
}
