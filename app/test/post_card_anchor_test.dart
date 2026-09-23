import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_reader/api/models.dart';
import 'package:simple_reader/api/simple_api.dart';
import 'package:simple_reader/state/paged_list.dart';
import 'package:simple_reader/ui/widgets/paged_post_list.dart';
import 'package:simple_reader/ui/widgets/post_card.dart';
import 'package:simple_reader/ui/widgets/read_tracker.dart';

/// 直接喂数据的假控制器：不缓存、不联网，按 10 条一页吐内容。
class _FakePagedController extends PagedListController {
  _FakePagedController({required super.tokenProvider});

  /// 内容总量（共 3 页），够滚动、够补页。
  static const int total = 30;

  /// 每条正文都写成"长文"，保证卡片上会出现「展开全文」。
  /// 文本长度可调：折叠/展开的高度差要足够明显，锚定校正才有意义。
  int textLength = 260;

  /// 第二代内容：置 true 后，第 1 页返回「5 条新动态 + 5 条旧的」，
  /// 用于「上次浏览到这儿」分界测试（模拟服务端插入了新内容）。
  bool nextGen = false;

  /// 测试入口：公开"记录上次浏览内容"（基类里是 @protected）。
  void markSnapshot() => snapshotPrevSession();

  @override
  String get scope => 'test:anchor';

  @override
  Future<PageResult<Post>> fetchPage({
    required String token,
    required String lastId,
    required CacheMode mode,
  }) async {
    if (nextGen && lastId.isEmpty) {
      final posts = <Post>[
        for (var i = 0; i < 5; i++)
          Post.fromJson({'id': 'n$i', 'content': '新内容 $i'}),
        for (var i = 0; i < 5; i++)
          Post.fromJson({'id': 'p$i', 'content': '内容 $i ${'啊' * textLength}'}),
      ];
      return PageResult<Post>(
        items: posts,
        nextCursor: posts.last.id,
        hasMore: true,
        fromCache: false,
      );
    }
    final start =
        lastId.isEmpty ? 0 : (int.tryParse(lastId.substring(1)) ?? 0) + 1;
    final posts = <Post>[];
    for (var i = start; i < start + 10 && i < total; i++) {
      posts.add(Post.fromJson({
        'id': 'p$i',
        'content': '内容 $i ${'啊' * textLength}',
      }));
    }
    return PageResult<Post>(
      items: posts,
      nextCursor: posts.isEmpty ? null : posts.last.id,
      hasMore: posts.length >= 10,
      fromCache: false,
    );
  }
}

/// 搭一个「真实卡片 + 真实分页列表」的环境，返回三件套供断言。
///
/// [textLength] 控制正文长度（要在 loadPage 之前设，内容在抓取时生成）；
/// [animated] 为 true 时用 AnimatedBuilder 包一层——控制器变化要驱动
/// 列表重建的场景（刷新出分界条）必须如此，真实页面（搜索页等）正是
/// 这么嵌的。
Future<({_FakePagedController ctl, ScrollController scroll, ItemVisibilityTracker tracker})>
    _pumpList(
  WidgetTester tester, {
  int textLength = 260,
  bool animated = false,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final ctl = _FakePagedController(tokenProvider: () => 'token');
  ctl.textLength = textLength;
  final scroll = ScrollController();
  final tracker = ItemVisibilityTracker(scroll);
  await ctl.loadPage(0, mode: CacheMode.networkFirst);
  await ctl.loadPage(1, mode: CacheMode.networkFirst);

  Widget buildList() => PagedPostList(
        controller: ctl,
        scrollController: scroll,
        tracker: tracker,
        enableRefresh: false,
        itemBuilder: (context, post, index) => PostCard(
          post: post,
          onTap: () {},
          onVote: (_) {},
          onFavourite: (_) {},
        ),
      );

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: animated
          ? AnimatedBuilder(animation: ctl, builder: (context, _) => buildList())
          : buildList(),
    ),
  ));
  await tester.pumpAndSettle();
  return (ctl: ctl, scroll: scroll, tracker: tracker);
}

/// 双指捏合（相向收拢 40px，超过卡片的 24px 触发阈值）。
///
/// 两指都落在 [at] 附近：先落第一指，再落第二指（初始间距 40px），
/// 随后两指各向中间移动 20px —— 卡片的 Listener 在移动帧里就能看到
/// 间距收拢超过阈值并触发折叠。
Future<void> _pinchCollapse(WidgetTester tester, Offset at) async {
  final first = await tester.startGesture(at);
  await tester.pump();
  final second = await tester.startGesture(at + const Offset(40, 0));
  await tester.pump();
  // 两指相向而行：间距 40 → 0，收拢量 40px ≥ 卡片的 24px 触发阈值。
  await first.moveBy(const Offset(20, 0));
  await second.moveBy(const Offset(-20, 0));
  await tester.pump();
  await first.up();
  await second.up();
  await tester.pumpAndSettle();
}

/// 收尾：把日志系统 900ms 的落盘定时器跑完。
///
/// 日志每次写入都会排一个定时器（落盘 + 镜像到系统日志），测试结束时若它
/// 还挂着，flutter_test 会以 "A Timer is still pending" 判失败。
/// 这里连推几轮：某一帧里可能又有代码写日志（锚定校正/放弃都会留痕），
/// 那只定时器要再推一次才到期。
Future<void> _drainLogTimer(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

void main() {
  testWidgets('双指捏合整条动态折叠成一行，单击还原', (tester) async {
    final env = await _pumpList(tester);
    const id = 'p1';

    final key = env.tracker.keyFor(id);
    expect(find.byKey(key), findsOneWidget);
    final before = tester.getSize(find.byKey(key)).height;
    expect(before, greaterThan(200));

    await _pinchCollapse(tester, tester.getCenter(find.byKey(key)));

    // 折叠后只剩一行摘要 + 「已折叠 · 点击展开」。
    expect(find.text('已折叠 · 点击展开'), findsOneWidget);
    final collapsed = tester.getSize(find.byKey(key)).height;
    expect(collapsed, lessThan(before / 2));

    // 折叠态单击还原。
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
    expect(find.text('已折叠 · 点击展开'), findsNothing);
    expect(tester.getSize(find.byKey(key)).height, closeTo(before, 1));

    await _drainLogTimer(tester);
  });

  testWidgets('展开正文后锚点条目留在原视口位置', (tester) async {
    final env = await _pumpList(tester);

    // 滚一段，让视口里既有被操作的卡片，也有它上面的内容。
    env.scroll.jumpTo(420);
    await tester.pumpAndSettle();

    // 锚点 = 视口里最靠上的已渲染条目，模拟列表内部的口径。
    final ids = <Object>[for (final p in env.ctl.posts) p.id];
    final anchor = env.tracker.firstVisibleKey(ids);
    expect(anchor, isNotNull, reason: '视口内应当有已渲染条目');

    final anchorFinder = find.byKey(env.tracker.keyFor(anchor!));
    final topBefore = tester.getTopLeft(anchorFinder).dy;

    // 点这张卡片自己的「展开全文」—— 高度变化的发起方就是锚点条目。
    // （展开全文在按钮栏里，单击直接命中，无须再推双击超时的假时钟。）
    final expand = find.descendant(
      of: anchorFinder,
      matching: find.text('展开全文'),
    );
    expect(expand, findsOneWidget);
    await tester.tap(expand);
    await tester.pumpAndSettle();

    // 展开后同一张卡片不应被推走（容 2px 的浮点/行高误差）。
    expect(
      tester.getTopLeft(anchorFinder).dy,
      closeTo(topBefore, 2),
      reason: '高度变化后锚点条目必须留在原视口位置，否则用户会看到大幅跳跃',
    );

    await _drainLogTimer(tester);
  });

  testWidgets('锚定校正不会把锚定期间的用户滚动撤销', (tester) async {
    final env = await _pumpList(tester);
    env.scroll.jumpTo(420);
    await tester.pumpAndSettle();

    final ids = <Object>[for (final p in env.ctl.posts) p.id];
    final anchor = env.tracker.firstVisibleKey(ids)!;
    final anchorFinder = find.byKey(env.tracker.keyFor(anchor));
    await tester.tap(
      find.descendant(of: anchorFinder, matching: find.text('展开全文')),
    );

    // 只推进一帧：此时锚定刚应用完第一次校正，后续帧还在排队。
    await tester.pump();

    // 用户自己滑走 200px。
    env.scroll.jumpTo(env.scroll.offset + 200);
    final afterUserScroll = env.scroll.offset;
    await tester.pumpAndSettle();

    // 安全阀生效：剩下的锚定校正必须放弃，不能把用户的滚动拽回去。
    expect(env.scroll.offset, closeTo(afterUserScroll, 2));

    await _drainLogTimer(tester);
  });

  testWidgets('长文浏览到中部折叠：折叠摘要收回到视口顶端', (tester) async {
    // 8000 字正文展开后约 8000+px，远超一屏——复现"11014px 长文浏览到
    // 中部捏合折叠"的场景。
    final env = await _pumpList(tester, textLength: 8000);

    // 展开 p1 的正文。「展开全文」在按钮栏里，单击直接命中。
    final key1 = env.tracker.keyFor('p1');
    await tester.tap(find.descendant(
      of: find.byKey(key1),
      matching: find.text('展开全文'),
    ));
    await tester.pumpAndSettle();
    final h1 = tester.getSize(find.byKey(key1)).height;
    expect(h1, greaterThan(4000), reason: '前置条件：p1 应已展开为远超一屏的长文');

    // 滚进 p1 的中部：p1 顶部已在视口上方，视口里全是 p1 的正文。
    env.scroll.jumpTo(h1 * 0.4);
    await tester.pumpAndSettle();
    expect(
      env.tracker.viewportTopOfKey('p1'),
      lessThan(0),
      reason: '前置条件：p1 顶部应已滚出视口上方',
    );

    // 在视口中央双指捏合 = 捏合 p1 整条 → 折叠。
    await _pinchCollapse(tester, tester.getCenter(find.byType(PagedPostList)));
    await tester.pumpAndSettle();

    // 折叠摘要必须停在视口顶端，且卡片本地折叠态不能丢（条目被回收重建
    // 会让折叠状态消失——预跳保证了条目始终在视口内）。
    expect(find.text('已折叠 · 点击展开'), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(key1)).dy, closeTo(0, 2));

    await _drainLogTimer(tester);
  });

  testWidgets('刷新抓到新内容后，旧内容前出现「上次浏览到这儿」分界', (tester) async {
    final env = await _pumpList(tester, animated: true);
    expect(find.text('上次浏览到这儿'), findsNothing);

    // 记下当前内容（p0..p19）作为"上次浏览的"，再让服务端"插入"5 条新动态。
    env.ctl.markSnapshot();
    env.ctl.nextGen = true;
    await env.ctl.refresh();
    await tester.pumpAndSettle();

    expect(find.text('上次浏览到这儿'), findsOneWidget);
    await _drainLogTimer(tester);
  });

  testWidgets('重抓后没有新内容时不显示分界', (tester) async {
    final env = await _pumpList(tester, animated: true);

    env.ctl.markSnapshot();
    await env.ctl.refresh(); // 内容没变：新列表里第一条就是旧内容
    await tester.pumpAndSettle();

    expect(find.text('上次浏览到这儿'), findsNothing);
    await _drainLogTimer(tester);
  });
}
