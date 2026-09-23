import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_reader/api/models.dart';
import 'package:simple_reader/api/simple_api.dart';
import 'package:simple_reader/state/paged_list.dart';
import 'package:simple_reader/ui/widgets/paged_post_list.dart';
import 'package:simple_reader/ui/widgets/post_card.dart';
import 'package:simple_reader/ui/widgets/read_tracker.dart';
import 'package:simple_reader/util/app_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ------------------------------------------------ waitFreshPagedLayout

  test('布局已含新数据（max 已变）：不等帧直接通过', () async {
    var waits = 0;
    final ok = await waitFreshPagedLayout(
      readMax: () => 16000,
      beforeMax: 8000,
      waitFrame: () async => waits++,
    );
    expect(ok, isTrue, reason: '补页后 max 变化，说明布局已含新页');
    expect(waits, 0, reason: '快路径不应额外等帧');
  });

  test('settleFrame 先于数据帧返回（帧竞态）：再等帧直到布局更新', () async {
    // 复现生产侧的竞态形态：补页后头两次读到的 max 都还是旧布局
    // （endOfFrame 落在 overscroll 动画旧帧上），第三次起才是新布局。
    var reads = 0;
    var waits = 0;
    final ok = await waitFreshPagedLayout(
      readMax: () => ++reads <= 2 ? 8000.0 : 16000.0,
      beforeMax: 8000,
      waitFrame: () async => waits++,
    );
    expect(ok, isTrue, reason: '多等几帧后必须等到新布局，不能静默放弃');
    expect(waits, 2, reason: '前两次读到旧布局，各补等一帧');
  });

  test('新页被去重/过滤整页吃掉（max 永不变）：等满上限后放弃', () async {
    var waits = 0;
    final ok = await waitFreshPagedLayout(
      readMax: () => 8000,
      beforeMax: 8000,
      waitFrame: () async => waits++,
    );
    expect(ok, isFalse, reason: 'max 始终未变 = 上方没有插入内容，无需补偿');
    expect(waits, 3, reason: '等满 maxRounds 轮后放弃');
  });

  // ------------------------------------------------ waitAnchorLanded

  test('锚点已位移（插入生效）：不等帧直接通过', () async {
    var waits = 0;
    final ok = await waitAnchorLanded(
      readTop: () => 9000,
      topBefore: 40,
      waitFrame: () async => waits++,
    );
    expect(ok, isTrue, reason: '锚点 top 位移 = 插入生效的直接证据');
    expect(waits, 0, reason: '快路径不应额外等帧');
  });

  test('数据帧晚于 settleFrame（帧竞态）：再等帧直到锚点位移', () async {
    var reads = 0;
    var waits = 0;
    final ok = await waitAnchorLanded(
      readTop: () => ++reads <= 2 ? 40.0 : 9000.0,
      topBefore: 40,
      waitFrame: () async => waits++,
    );
    expect(ok, isTrue, reason: '多等几帧后必须等到锚点位移，不能静默放弃');
    expect(waits, 2, reason: '前两次读到旧布局，各补等一帧');
  });

  test('新页被整页吃掉（锚点永不动）：等满上限后放弃', () async {
    var waits = 0;
    final ok = await waitAnchorLanded(
      readTop: () => 40,
      topBefore: 40,
      waitFrame: () async => waits++,
    );
    expect(ok, isFalse, reason: '锚点始终未位移 = 上方没有插入内容，无需补偿');
    expect(waits, 4, reason: '等满默认 maxRounds=4 轮后放弃');
  });

  test('锚点被挤出布局（readTop=null）不等于位移：继续等帧', () async {
    // null（测不到）必须与"位移"严格区分，否则误判已落库。
    var waits = 0;
    final ok = await waitAnchorLanded(
      readTop: () => null,
      topBefore: 40,
      waitFrame: () async => waits++,
    );
    expect(ok, isFalse);
    expect(waits, 4);
  });

  // ------------------------------------------------ 端到端：跳页后向上补页

  /// 直接喂数据的假控制器：p0..p29 按 10 条一页吐出。
  ///
  /// 用 [jumpToPage] 把窗口收敛到第 2 页（对齐 log-3 场景：跳页落顶后
  /// 用户顶在 0 点向上越界拉伸触发补页）。
  testWidgets('跳页落顶后向上补上一页：锚点条目必须留在原视口位置',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final ctl = _FakePagedController(tokenProvider: () => 'token');
    final scroll = ScrollController();
    final tracker = ItemVisibilityTracker(scroll);

    await ctl.loadPage(0, mode: CacheMode.networkFirst);
    await ctl.loadPage(1, mode: CacheMode.networkFirst);
    // 收敛到第 2 页（index 1）：窗口只剩它，向上补页的目标是第 1 页。
    final jumped = await ctl.jumpToPage(1, mode: CacheMode.networkFirst);
    expect(jumped, isTrue);
    expect(ctl.firstPage, 1, reason: '前置条件：窗口已收敛到第 2 页');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AnimatedBuilder(
          animation: ctl,
          builder: (context, _) => PagedPostList(
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
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(scroll.offset, 0, reason: '前置条件：视口停在列表顶端');
    final key10 = tracker.keyFor('p10');
    final topBefore = tester.getTopLeft(find.byKey(key10)).dy;
    expect(topBefore, greaterThan(0), reason: '前置条件：第 2 页首条已渲染');

    // 手指顶在列表顶端向上越界拉伸 → OverscrollNotification → 触发补页。
    // 数据落地时机用 gate 控制：先跑过一帧"无数据的旧帧"、手指也先松开，
    // 再放行数据 —— 对齐生产侧"补页发生在 overscroll 动画帧流中"的时序；
    // 同时保证校正 jumpTo 发生在松手之后（jumpTo 会接管滚动活动），
    // 不被松手惯性甩走，结果才是确定的。
    ctl.fetchGate = Completer<void>();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PagedPostList)),
    );
    await gesture.moveBy(const Offset(0, -160));
    await tester.pump();
    await gesture.up();
    ctl.fetchGate!.complete();
    await tester.pumpAndSettle();

    // 第 1 页已补进窗口顶上。
    expect(ctl.firstPage, 0, reason: '补上一页应把第 1 页接在开头');

    // 诊断：视口最终停在哪、校正走了哪条路径（失败时从输出直接可读）。
    // ignore: avoid_print
    print('补页后 offset=${scroll.offset.toStringAsFixed(1)} '
        'max=${scroll.position.maxScrollExtent.toStringAsFixed(1)}');
    for (final id in const ['p9', 'p10', 'p11', 'p19']) {
      final k = tracker.keyFor(id);
      // ignore: avoid_print
      print('diag $id mounted=${k.currentContext != null} '
          'viewportTop=${tracker.viewportTopOfKey(id)?.toStringAsFixed(1)} '
          'contentOffset=${tracker.offsetOfKey(id)?.toStringAsFixed(1)}');
    }
    // ignore: avoid_print
    print('diag posts=${ctl.posts.map((p) => p.id).take(3).join(',')}'
        '…${ctl.posts.map((p) => p.id).last} pages=${ctl.pageCount}');
    // ignore: avoid_print
    for (final e in log.entries.where((e) => e.tag == LogTag.page).take(8)) {
      // ignore: avoid_print
      print('LOG ${e.level.name} ${e.message}');
    }

    // 补页校正必须生效：第 2 页首条留在原视口位置（容 2px 浮点误差），
    // 否则就是"画面整体跳一页"——正是本次修复的缺陷表现。
    expect(
      tester.getTopLeft(find.byKey(key10)).dy,
      closeTo(topBefore, 2),
      reason: '补上一页后锚点条目必须留在原视口位置，画面不允许跳变',
    );

    // P1-A 验证：探照灯开启后，粗校正必须走「锚点实测」路径 —— 这正是
    // 实机跳变根因（max-增量兜底拿估计值当 Δ）的修复点。
    expect(
      log.entries.any((e) =>
          e.tag == LogTag.page &&
          e.message.contains('补上一页后校正滚动') &&
          e.message.contains('（锚点实测）')),
      isTrue,
      reason: '探照灯窗口内锚点可实测，粗校正必须走锚点实测路径',
    );
    expect(
      log.entries.any((e) =>
          e.tag == LogTag.page &&
          e.message.contains('补上一页收尾') &&
          e.message.contains('守卫=通过')),
      isTrue,
      reason: '补页事件应以收尾汇总行结束',
    );

    // 收尾：把日志系统 900ms 的落盘定时器跑完，避免挂起定时器判失败。
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  });

  // ------------------------------------------------ 端到端：守卫自愈

  /// 校正落地后注入一次"锚点上方相邻条目加高 100px"的异常漂移（offset
  /// 不变、锚点被推离原位），自愈层必须把它修回原视口位置。
  ///
  /// 注入时机：粗校明日志出现后再推进一帧（精修在干净校正下当帧测得
  /// 残余≈0 并退出，守卫开始观察），此刻注入落在守卫窗口内。若时序
  /// 偏移导致精修先修掉，同样算通过（两层自愈任一生效即可）。
  ///
  /// 注入载体：p9（锚点 p10 的上一条，恰在默认 cacheExtent 内被布局）
  /// 外包一个可变高度的占位 —— 页眉变高等"列表外部"的改动只压缩视口、
  /// 不移动条目相对视口的位置，无法构成漂移。
  testWidgets('校正后注入异常漂移：自愈层必须把锚点修回原位', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final ctl = _FakePagedController(tokenProvider: () => 'token');
    final scroll = ScrollController();
    final tracker = ItemVisibilityTracker(scroll);
    final extraAbove = ValueNotifier<double>(0);
    addTearDown(extraAbove.dispose);

    await ctl.loadPage(0, mode: CacheMode.networkFirst);
    await ctl.loadPage(1, mode: CacheMode.networkFirst);
    final jumped = await ctl.jumpToPage(1, mode: CacheMode.networkFirst);
    expect(jumped, isTrue);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AnimatedBuilder(
          animation: ctl,
          builder: (context, _) => PagedPostList(
            controller: ctl,
            scrollController: scroll,
            tracker: tracker,
            enableRefresh: false,
            itemBuilder: (context, post, index) {
              final card = PostCard(
                post: post,
                onTap: () {},
                onVote: (_) {},
                onFavourite: (_) {},
              );
              if (post.id != 'p9') return card;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ValueListenableBuilder<double>(
                    valueListenable: extraAbove,
                    builder: (context, h, _) =>
                        SizedBox(height: h, width: double.infinity),
                  ),
                  card,
                ],
              );
            },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final key10 = tracker.keyFor('p10');
    final topBefore = tester.getTopLeft(find.byKey(key10)).dy;

    ctl.fetchGate = Completer<void>();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PagedPostList)),
    );
    await gesture.moveBy(const Offset(0, -160));
    await tester.pump();
    await gesture.up();
    ctl.fetchGate!.complete();

    // 逐帧推进到粗校明日志出现，再推进一帧（跳过精修的当帧测量），
    // 然后在守卫观察窗口内注入异常漂移。
    var coarseSeen = false;
    for (var i = 0; i < 20 && !coarseSeen; i++) {
      await tester.pump();
      coarseSeen = log.entries.any((e) =>
          e.tag == LogTag.page && e.message.contains('补上一页后校正滚动'));
    }
    expect(coarseSeen, isTrue, reason: '粗校明日志应出现');
    await tester.pump();
    extraAbove.value = 100; // p9 加高 → p10 及以下整体下移，offset 不变
    await tester.pumpAndSettle();

    // 自愈层（守卫，或时序偏移时的精修）必须把锚点修回原位。
    final healed = log.entries.any((e) =>
        e.tag == LogTag.page && e.message.contains('校正后自愈'));
    final fineFixed = log.entries.any((e) =>
        e.tag == LogTag.page && e.message.contains('补页校正精修'));
    expect(healed || fineFixed, isTrue,
        reason: '注入的异常漂移必须被自愈层（守卫或精修）修回');
    expect(
      tester.getTopLeft(find.byKey(key10)).dy,
      closeTo(topBefore, 2),
      reason: '自愈后锚点必须回到原视口位置，画面不允许带伤停留',
    );

    // 收尾：跑完日志落盘定时器。
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  });
}

class _FakePagedController extends PagedListController {
  _FakePagedController({required super.tokenProvider});

  /// 非空时，fetchPage 等它完成后再吐数据（测试用来控制数据落地时机）。
  Completer<void>? fetchGate;

  @override
  String get scope => 'test:prevfresh';

  @override
  Future<PageResult<Post>> fetchPage({
    required String token,
    required String lastId,
    required CacheMode mode,
  }) async {
    if (fetchGate != null) await fetchGate!.future;
    final start =
        lastId.isEmpty ? 0 : (int.tryParse(lastId.substring(1)) ?? 0) + 1;
    final posts = <Post>[
      for (var i = start; i < start + 10; i++)
        Post.fromJson({'id': 'p$i', 'content': '内容 $i ${'啊' * 60}'}),
    ];
    return PageResult<Post>(
      items: posts,
      nextCursor: posts.last.id,
      hasMore: true,
      fromCache: false,
    );
  }
}
