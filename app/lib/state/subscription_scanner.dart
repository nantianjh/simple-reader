import '../api/api_config.dart';
import '../api/simple_api.dart';
import '../data/favourite_collections.dart';
import '../util/app_log.dart';

/// 订阅合集的冷启动扫描器。
///
/// 需求：用户给收藏的合集打上「订阅」标记后，每次冷启动都检查一遍
/// 订阅合集里有没有新动态，有则在合集名称右侧显示红点。
///
/// 执行口径：
/// * **串行** —— 逐个合集 await，请求本身再由 ApiClient 统一限速
///   （≥1.2 秒间隔），绝不并发；
/// * 只拉每个合集的**最新一页**（10 条），拿首条动态 id 与本地基线
///   （[FavCollection.lastSeenTopPostId]）对比，不同即有新动态；
/// * 单个合集失败不中断整轮，留到下次冷启动再试。
class SubscriptionScanner {
  SubscriptionScanner({
    required this.tokenProvider,
    SimpleApi? api,
  }) : _api = api ?? SimpleApi();

  /// 每次请求实时取 token。
  final String? Function() tokenProvider;

  final SimpleApi _api;

  bool _running = false;

  /// 是否正在扫描（防止重复触发）。
  bool get running => _running;

  /// 扫描全部订阅合集。[ownerUserId] 用于判断合集是否自己的
  /// （posts/mine 或 posts/profile）。
  Future<void> scan({String ownerUserId = ''}) async {
    if (_running) return;
    final token = tokenProvider();
    if (token == null || token.isEmpty) return;
    final subs = FavouriteCollectionsStore.instance.subscribedItems;
    if (subs.isEmpty) return;

    _running = true;
    final sw = Stopwatch()..start();
    log.i(LogTag.fav, '冷启动扫描订阅合集：${subs.length} 个（串行）');
    var done = 0;
    var marked = 0;
    try {
      for (final c in subs) {
        try {
          final page = await _api.fetchCollectionPosts(
            token: token,
            collectionId: c.id,
            authorId: c.authorId,
            mine: ownerUserId.isNotEmpty && ownerUserId == c.authorId,
            perPage: ApiConfig.defaultPerPage,
            mode: CacheMode.networkFirst,
          );
          final top = page.items.isEmpty ? '' : page.items.first.id;
          final before = c.hasNew;
          await FavouriteCollectionsStore.instance.applyScan(c.id, top);
          done++;
          // applyScan 改的是 store 里的条目，这里重读一次判断是否新标了红点。
          final after = FavouriteCollectionsStore.instance.byId(c.id);
          if (!before && (after?.hasNew ?? false)) marked++;
          log.d(
            LogTag.fav,
            '订阅扫描：${c.name}（${c.id}）→ 首条=$top，'
            '${c.hasNew ? '有新动态' : '无新动态'}',
          );
        } catch (e) {
          // 单个合集失败只记日志：可能下周一开始的那几条也能扫到。
          log.w(LogTag.fav, '订阅扫描失败：${c.name}（${c.id}）｜$e');
        }
      }
    } finally {
      _running = false;
      log.i(
        LogTag.fav,
        '订阅扫描结束：完成 $done/${subs.length} 个，'
        '新标红点 $marked 个${AppLog.ms(sw)}',
      );
    }
  }
}
