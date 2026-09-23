import '../api/api_config.dart';
import '../api/models.dart';
import '../api/simple_api.dart';
import '../data/reading_positions.dart';
import 'paged_list.dart';

/// 收藏夹控制器。
///
/// 内容流原先支持「广场 / 推荐 / 收藏」三源，按需求只保留收藏：
/// * 广场（`posts/channels/all`）与推荐（`posts/recommendations`）不再作为
///   本客户端的入口；
/// * 收藏走 [SimpleApi.fetchFavourites]，接口候选按顺序探测。
///
/// 分页与续读行为与搜索一致（见 [PagedListController]）。
class FavoritesController extends PagedListController {
  FavoritesController({
    required super.tokenProvider,
    SimpleApi? api,
  }) : _api = api ?? SimpleApi();

  final SimpleApi _api;

  /// 实际探测成功的接口，供 UI 展示与排查。
  String get endpointLabel => _api.resolvedFavouritesEndpoint.label;

  @override
  String get scope => ReadScope.favourites;

  @override
  Future<PageResult<Post>> fetchPage({
    required String token,
    required String lastId,
    required CacheMode mode,
  }) =>
      _api.fetchFavourites(
        token: token,
        lastId: lastId,
        perPage: ApiConfig.defaultPerPage,
        mode: mode,
      );

  /// 进入页面时若尚未加载则加载第一页。
  Future<void> ensureLoaded() async {
    if (loadedOnce || busy) return;
    ran = true;
    beginLoad();
    await loadPage(0);
    finishLoad();
  }
}
