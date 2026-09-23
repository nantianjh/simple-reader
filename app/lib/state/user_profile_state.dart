import '../api/api_config.dart';
import '../api/models.dart';
import '../api/simple_api.dart';
import 'paged_list.dart';

/// 他人主页的动态流控制器（GET api/v2/posts/profile?user_id=）。
///
/// 与合集内容同端点、不带合集参数。续读作用域按用户隔离，
/// 避免和搜索/收藏的续读点互相覆盖。
class UserProfilePostsController extends PagedListController {
  UserProfilePostsController({
    required super.tokenProvider,
    required this.userId,
    SimpleApi? api,
  }) : _api = api ?? SimpleApi();

  final SimpleApi _api;

  /// 主页主人的用户 id。
  final String userId;

  @override
  String get scope => 'user_posts:$userId';

  @override
  Future<PageResult<Post>> fetchPage({
    required String token,
    required String lastId,
    required CacheMode mode,
  }) =>
      _api.fetchUserPosts(
        token: token,
        userId: userId,
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
