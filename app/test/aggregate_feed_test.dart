// 「综合阅读」控制器守卫：合并排序 / 去重 / 追加载 / 「上次浏览到这儿」各自停止。
//
// 取数层是 AggregateFetcher 函数类型，测试直接注入假实现（工程零第三方
// 依赖，不引 mock 框架），与 paged_jump_test 的"假控制器"同一思路。

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_reader/api/models.dart';
import 'package:simple_reader/api/simple_api.dart';
import 'package:simple_reader/state/aggregate_feed.dart';

Post post(String id, int minutesAgo) => Post.fromJson({
      'id': id,
      'content': '内容 $id',
      'created_at': DateTime(2026, 10, 9, 12)
          .subtract(Duration(minutes: minutesAgo))
          .toIso8601String(),
    });

PageResult<Post> page(
  List<Post> items, {
  bool hasMore = false,
}) =>
    PageResult<Post>(
      items: items,
      nextCursor: hasMore ? 'next' : null,
      hasMore: hasMore,
    );

/// 脚本化假取数层：按关键词依次吐出预设页（游标语义由控制器负责，这里
/// 只按调用次序返回，便于精确断言"抓了几页"）。
class FakeFeed {
  FakeFeed(this.script);

  /// 关键词 → 依次返回的各页。
  final Map<String, List<PageResult<Post>>> script;
  final Map<String, int> _next = <String, int>{};

  /// 调用流水（`关键词#第几次调用`）。
  final List<String> calls = <String>[];

  Future<PageResult<Post>> fetch({
    required String keyword,
    required String token,
    String lastId = '',
    int perPage = 10,
    CacheMode mode = CacheMode.preferCache,
  }) async {
    final i = _next[keyword] ?? 0;
    _next[keyword] = i + 1;
    calls.add('$keyword#${i + 1}');
    final pages = script[keyword] ?? const <PageResult<Post>>[];
    if (i >= pages.length) return PageResult.empty<Post>();
    return pages[i];
  }
}

AggregateFeedController makeController(FakeFeed fake) =>
    AggregateFeedController(
      tokenProvider: () => 'token',
      fetcher: fake.fetch,
    );

void main() {
  test('多关键词合并：按发布时间从新到旧，重复内容只留一条', () async {
    final fake = FakeFeed({
      'a': [
        page([post('a1', 1), post('共享', 4)], hasMore: true),
      ],
      'b': [
        page([post('b1', 2), post('共享', 4)]),
      ],
    });
    final ctl = makeController(fake);
    await ctl.start(['a', 'b']);

    expect(ctl.posts.map((p) => p.id).toList(), ['a1', 'b1', '共享']);
    expect(ctl.itemCount, 3);
    expect(ctl.hasMore, isTrue);
    expect(ctl.autoFetchStopReason, isNull);
  });

  test('追加载：一轮 = 每个还有下一页的词各取一页；到底后 exhausted', () async {
    final fake = FakeFeed({
      'a': [
        page([post('a1', 1)], hasMore: true),
        page([post('a2', 8)]),
      ],
      'b': [
        page([post('b1', 2)], hasMore: true),
        page([post('b2', 9)]),
      ],
    });
    final ctl = makeController(fake);
    await ctl.start(['a', 'b']);
    expect(ctl.posts.map((p) => p.id).toList(), ['a1', 'b1']);

    await ctl.loadMore();
    expect(ctl.posts.map((p) => p.id).toList(), ['a1', 'b1', 'a2', 'b2']);
    expect(ctl.hasMore, isFalse);
    expect(ctl.exhausted, isTrue);
  });

  test('分界：强制重抓时每个词各自接上自己上次的内容即停，互不牵连', () async {
    final fake = FakeFeed({
      'a': [
        // 第一次进入
        page([post('a1', 10)], hasMore: true),
        // 再次打开第 1 页：全是新内容 → 还没接上
        page([post('a5', 1), post('a4', 2)], hasMore: true),
        // 自动续抓第 2 页：出现上次抓到过的 a1 → 接上，停止
        page([post('a1', 10)], hasMore: true),
      ],
      'b': [
        page([post('b1', 20)], hasMore: true),
        // 再次打开第 1 页就带上了 b1 → 直接接上，不再往下抓
        page([post('b2', 5), post('b1', 20)], hasMore: true),
      ],
      'c': [
        // 新词（第一次进入时不在名单里）：没有上次留档，不参与自动续抓
        page([post('c9', 3)], hasMore: true),
        page([post('c0', 30)]),
      ],
    });
    final ctl = makeController(fake);

    await ctl.start(['a', 'b']); // 第一次进入：各抓 1 页
    expect(ctl.autoFetchStopReason, isNull);

    await ctl.start(['a', 'b', 'c'], forceNetwork: true); // 刷新语义
    expect(ctl.autoFetchStopReason, 'boundary');

    // a：第 1 页没接上 → 续抓第 2 页；b：第 1 页就接上，不续抓；
    // c：没有留档，自动续抓不碰它（只随首轮抓 1 页）。
    expect(
      fake.calls.where((c) => c.startsWith('a#')).toList(),
      ['a#1', 'a#2', 'a#3'],
    );
    expect(
      fake.calls.where((c) => c.startsWith('b#')).toList(),
      ['b#1', 'b#2'],
    );
    expect(
      fake.calls.where((c) => c.startsWith('c#')).toList(),
      ['c#1'],
    );

    // 合并结果仍然按发布时间从新到旧（新内容和接上分界的那条同列表）。
    expect(
      ctl.posts.map((p) => p.id).toList(),
      ['a5', 'a4', 'c9', 'b2', 'a1', 'b1'],
    );
  });

  test('首次使用（没有上次留档）不做自动续抓', () async {
    final fake = FakeFeed({
      'a': [
        page([post('a1', 1)], hasMore: true),
        page([post('a2', 9)]),
      ],
    });
    final ctl = makeController(fake);
    await ctl.start(['a'], forceNetwork: true);

    expect(ctl.autoFetchStopReason, isNull);
    expect(fake.calls, ['a#1']);
  });

  test('关键词名单为空：不取数、结果为空的空态', () async {
    final fake = FakeFeed({});
    final ctl = makeController(fake);
    await ctl.start([]);

    expect(fake.calls, isEmpty);
    expect(ctl.keywords, isEmpty);
    expect(ctl.posts, isEmpty);
  });
}
