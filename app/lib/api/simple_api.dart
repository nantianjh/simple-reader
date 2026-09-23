import 'dart:async';

import '../data/content_cache.dart';
import '../data/vote_overlay.dart';
import '../data/vote_states.dart';
import '../util/app_log.dart';
import 'api_client.dart';
import 'api_config.dart';
import 'api_exception.dart';
import 'models.dart';

/// 缓存读取策略。
enum CacheMode {
  /// 缓存优先：命中即用，未命中才走网络。常规进入页面用这一档。
  preferCache,

  /// 强制网络：跳过缓存；网络失败时回落到（可能已过期的）缓存。
  /// 下拉刷新用这一档。
  networkFirst,

  /// 只读缓存，不发任何请求。续读上次位置时用这一档——
  /// 续读的语义就是"接着看本地已有的内容"，不产生新的抓取。
  /// 未命中时返回 `cacheMiss`，由调用方决定是否再抓。
  cacheOnly,
}

/// 一页结果。游标式分页的统一载体。
class PageResult<T> {
  const PageResult({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
    this.fromCache = false,
    this.cacheMiss = false,
    this.cachedAt,
  });

  final List<T> items;

  /// 下一页的 `last_id`。无更多数据时为 null。
  final String? nextCursor;

  final bool hasMore;

  /// 本页数据是否来自本地缓存（UI 据此提示"来自缓存"）。
  final bool fromCache;

  /// [CacheMode.cacheOnly] 且本地没有该请求的缓存。
  final bool cacheMiss;

  /// 缓存写入时间，仅在 [fromCache] 为 true 时有值。
  final DateTime? cachedAt;

  static PageResult<T> empty<T>() =>
      PageResult<T>(items: const [], nextCursor: null, hasMore: false);

  static PageResult<T> miss<T>() => PageResult<T>(
        items: const [],
        nextCursor: null,
        hasMore: false,
        cacheMiss: true,
      );

  PageResult<R> cast<R>(List<R> items) => PageResult<R>(
        items: items,
        nextCursor: nextCursor,
        hasMore: hasMore,
        fromCache: fromCache,
        cacheMiss: cacheMiss,
        cachedAt: cachedAt,
      );
}

/// 收藏夹候选接口。
///
/// 探查报告第二条实测：`GET api/v2/favourites` → 200，返回**动态**列表
/// （Post 模型），支持 `last_id` / `per_page` 游标分页。
/// 第二个候选是《Simplexcel 报告》里本地代理的转发形态，保留为兜底探测。
///
/// 探测结果只在本次进程内记忆，避免每次翻页都重复试探。
class FavouritesEndpoint {
  const FavouritesEndpoint(this.label, this.path, [this.source]);

  /// 展示与排查用的名字。
  final String label;

  /// 相对 [ApiConfig.baseUrl] 的路径。
  final String path;

  /// 需要以查询参数形式传入的数据源名。
  final String? source;

  static const List<FavouritesEndpoint> candidates = <FavouritesEndpoint>[
    FavouritesEndpoint('api/v2/favourites', 'api/v2/favourites'),
    FavouritesEndpoint(
      'api/v2/posts?source=favourites',
      'api/v2/posts',
      'favourites',
    ),
  ];

  /// 给错误提示用的一句话清单。
  static String get triedLabels =>
      candidates.map((c) => c.label).join('、');
}

/// 原始行 + 来源信息（内部类型）。
class _RawPage {
  const _RawPage({
    required this.rows,
    this.fromCache = false,
    this.cacheMiss = false,
    this.cachedAt,
  });

  final List<Map<String, dynamic>> rows;
  final bool fromCache;
  final bool cacheMiss;
  final DateTime? cachedAt;
}

/// 业务 API 门面。
class SimpleApi {
  SimpleApi({ApiClient? client}) : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  /// 探测成功的收藏接口。null 表示尚未探测出结果。
  FavouritesEndpoint? _favouritesEndpoint;

  /// 上一次合集内容请求实际用的端点（`posts/profile` 或 `posts/mine`）。
  String _lastCollectionPostsPath = 'posts/profile';

  /// 收藏夹实际使用的接口（未探测时返回第一个候选，供 UI 提示用）。
  FavouritesEndpoint get resolvedFavouritesEndpoint =>
      _favouritesEndpoint ?? FavouritesEndpoint.candidates.first;

  /// 合集内容实际使用的取数口径，供 UI 在空列表时说明情况。
  String get resolvedCollectionPostsLabel =>
      'api/v2/$_lastCollectionPostsPath'
      '?user_id=<作者>&post_collection_id=<合集>&per_page=${ApiConfig.defaultPerPage}';

  // ---------------------------------------------------------------- v3 搜索

  /// v3 内容搜索。返回按 `created_at` 倒序的原始列表。
  ///
  /// [lastId] 首页传空串（契约第三节明确要求），翻页传上一页最后一条的 id。
  ///
  /// 已抓取的内容会按请求签名落盘缓存，后续同样的请求直接命中本地，
  /// 不再产生网络流量——这既是省流，也是契约第六节「保持低频率」的体现。
  Future<_RawPage> _searchRaw({
    required String keyword,
    required String token,
    String lastId = '',
    int perPage = ApiConfig.defaultPerPage,
    CacheMode mode = CacheMode.preferCache,
  }) {
    const path = 'posts/search';
    final signature = CacheKey.search(
      path: path,
      keyword: keyword,
      lastId: lastId,
      perPage: perPage,
    );
    return _fetchWithCache(
      signature: signature,
      mode: mode,
      request: () async {
        final decoded = await _client.getJson(
          '${ApiConfig.apiV3}$path',
          token: token,
          query: {
            // 契约第三节：参数名是 `q`，不是 `keyword`。
            'q': keyword,
            // 官方 Web 端固定传字符串 "10"。
            'per_page': perPage.toString(),
            // 首页传空串。
            'last_id': lastId,
          },
        );
        return extractMapList(decoded);
      },
    );
  }

  /// 缓存 + 网络的分发逻辑，搜索与收藏共用。
  Future<_RawPage> _fetchWithCache({
    required String signature,
    required CacheMode mode,
    required Future<List<Map<String, dynamic>>> Function() request,
  }) async {
    if (mode == CacheMode.preferCache) {
      final hit = await ContentCache.instance.read(signature);
      if (hit != null) {
        return _RawPage(
          rows: hit.rows,
          fromCache: true,
          cachedAt: hit.savedAt,
        );
      }
    } else if (mode == CacheMode.cacheOnly) {
      // 续读场景：允许拿到略过期的内容，目标是"不发请求就能接着看"。
      final hit =
          await ContentCache.instance.read(signature, ignoreExpiry: true);
      if (hit != null) {
        return _RawPage(rows: hit.rows, fromCache: true, cachedAt: hit.savedAt);
      }
      return const _RawPage(rows: [], cacheMiss: true);
    }

    try {
      final rows = await request();
      // 落盘失败不影响本次结果。
      unawaited(ContentCache.instance.write(signature, rows));
      return _RawPage(rows: rows);
    } catch (_) {
      // 强制刷新失败时，宁可给用户看略旧的内容，也不要一个空白页。
      if (mode == CacheMode.networkFirst) {
        final hit =
            await ContentCache.instance.read(signature, ignoreExpiry: true);
        if (hit != null) {
          return _RawPage(
            rows: hit.rows,
            fromCache: true,
            cachedAt: hit.savedAt,
          );
        }
      }
      rethrow;
    }
  }

  /// 搜索内容帖。
  Future<PageResult<Post>> searchPosts({
    required String keyword,
    required String token,
    String lastId = '',
    int perPage = ApiConfig.defaultPerPage,
    CacheMode mode = CacheMode.preferCache,
  }) async {
    final page = await _searchRaw(
      keyword: keyword,
      token: token,
      lastId: lastId,
      perPage: perPage,
      mode: mode,
    );
    if (page.cacheMiss) return PageResult.miss<Post>();
    final posts =
        page.rows.map(Post.fromJson).where((p) => p.id.isNotEmpty).toList();
    // 缓存来源套用本地点赞覆盖层；网络来源对账（服务端为准）。
    await VoteOverlay.instance.syncPosts(posts, fromCache: page.fromCache);
    return _buildPage(page, posts, perPage);
  }

  /// 搜索某页的本地缓存是否存在（只读缓存文件，**不发任何请求**）。
  ///
  /// 供续读恢复「缓存深度」用：旧存档没记这个数，只能拿游标链上最深一格
  /// 的签名去探测 —— 签名必须与 [searchPosts] 的实际口径完全一致，否则
  /// 探测结果不可信（这里复用同一个 [CacheKey.search]）。
  Future<bool> hasCachedSearchPage({
    required String keyword,
    required String lastId,
    int perPage = ApiConfig.defaultPerPage,
  }) async {
    const path = 'posts/search';
    final signature = CacheKey.search(
      path: path,
      keyword: keyword,
      lastId: lastId,
      perPage: perPage,
    );
    final hit = await ContentCache.instance.read(signature, ignoreExpiry: true);
    return hit != null;
  }

  // ------------------------------------------------------------ v2 内容读写

  /// 我的收藏夹（一页）。
  ///
  /// 候选接口依次探测：能拿到响应（哪怕是空列表）就固定下来；
  /// 遇到错误换下一个；全部失败才报错，并在提示里列出试过哪些接口。
  Future<PageResult<Post>> fetchFavourites({
    required String token,
    String lastId = '',
    int perPage = ApiConfig.defaultPerPage,
    CacheMode mode = CacheMode.preferCache,
  }) async {
    final ordered = <FavouritesEndpoint>[
      if (_favouritesEndpoint != null) _favouritesEndpoint!,
      ...FavouritesEndpoint.candidates
          .where((c) => c.path != _favouritesEndpoint?.path ||
              c.source != _favouritesEndpoint?.source),
    ];

    Object? lastError;
    for (final endpoint in ordered) {
      final signature = CacheKey.favourites(
        path: endpoint.path,
        source: endpoint.source,
        lastId: lastId,
        perPage: perPage,
      );

      _RawPage page;
      try {
        page = await _fetchWithCache(
          signature: signature,
          mode: mode,
          request: () async {
            final query = <String, dynamic>{
              'per_page': perPage.toString(),
              'last_id': lastId,
            };
            if (endpoint.source != null) query['source'] = endpoint.source;
            final decoded =
                await _client.getJson(endpoint.path, token: token, query: query);
            return extractMapList(decoded);
          },
        );
      } catch (e) {
        lastError = e;
        continue;
      }

      // 只读缓存时未命中是常态，换下一个候选试试它有没有缓存。
      if (page.cacheMiss) continue;

      _favouritesEndpoint = endpoint;
      final posts =
          page.rows.map(Post.fromJson).where((p) => p.id.isNotEmpty).toList();
      await VoteOverlay.instance.syncPosts(posts, fromCache: page.fromCache);
      log.d(
        LogTag.fav,
        '收藏动态取自 ${endpoint.label}：${posts.length} 条'
        '（lastId=${lastId.isEmpty ? '首页' : lastId}，'
        '来源=${page.fromCache ? '本地缓存' : '网络'}）',
      );
      return _buildPage(page, posts, perPage);
    }

    // 只读缓存且所有候选都没缓存：按"未命中"处理，由上层决定是否联网。
    if (mode == CacheMode.cacheOnly) return PageResult.miss<Post>();

    log.e(LogTag.fav, '所有候选接口都取不到收藏动态：${FavouritesEndpoint.triedLabels}');
    throw _probeFailure(
      lastError,
      '收藏接口',
      FavouritesEndpoint.triedLabels,
    );
  }

  /// 单个合集的头部信息。
  ///
  /// 探查报告 9.5：**只有 v3 的 `/{id}` 支持 GET**（v2 同路径 405），
  /// 且 v3 版本才带 `user_id` / `is_favourited` / `posts_count`。
  /// 本项目用它补出「合集共 N 条」与「我是否收藏了这个合集」。
  ///
  /// 不落内容缓存：它只是一条头部元信息，请求频率低、体积小，
  /// 且过期数据（条数/收藏态）反而会误导用户。
  Future<PostCollection?> fetchCollectionMeta({
    required String token,
    required String collectionId,
  }) async {
    if (collectionId.isEmpty) return null;
    final decoded = await _client.getJson(
      '${ApiConfig.apiV3}post_collections/$collectionId',
      token: token,
    );
    final map = extractMap(decoded);
    if (map == null) return null;
    final c = PostCollection.fromJson(map);
    return c.id.isEmpty ? null : c;
  }

  /// 某个合集里的动态。
  ///
  /// 取数口径来自探查报告第十节（已做完整性校验：翻到耗尽 20 条 =
  /// 合集声明的 `posts_count` 20，不重不漏）：
  ///
  /// ```
  /// GET api/v2/posts/profile?user_id=<作者id>&post_collection_id=<合集id>&last_id=&per_page=10
  /// ```
  ///
  /// * [authorId] 必须传 **合集作者** 的 id，不是合集 id；
  /// * 自己的合集走 `posts/mine`，参数相同；
  /// * **不要**改用 `api/v2/posts?post_collection_id=`：该参数会被服务端
  ///   静默忽略，返回"该作者的全部动态"，数据看起来对但完全是错的。
  ///
  /// 因此这里保留一道语义校验：返回项若逐条声明了别的合集 id，即判定
  /// 过滤未生效并直接报错，绝不把错误的列表当成功结果交给上层。
  Future<PageResult<Post>> fetchCollectionPosts({
    required String token,
    required String collectionId,
    required String authorId,
    required bool mine,
    String lastId = '',
    int perPage = ApiConfig.defaultPerPage,
    CacheMode mode = CacheMode.preferCache,
  }) async {
    if (collectionId.isEmpty) {
      throw ApiException(ApiErrorKind.unknown, '缺少合集 id，无法查询合集内容。');
    }
    if (authorId.isEmpty) {
      throw ApiException(
        ApiErrorKind.unknown,
        '缺少合集作者 id，无法查询合集内容。\n'
        '合集内容按「作者 + 合集」双参数过滤，作者信息来自收录它的那条动态。',
      );
    }

    // 自己的合集走 posts/mine，他人的走 posts/profile。
    final path = mine ? 'posts/mine' : 'posts/profile';
    _lastCollectionPostsPath = path;

    final signature = CacheKey.collectionPosts(
      path: path,
      authorId: authorId,
      collectionId: collectionId,
      lastId: lastId,
      perPage: perPage,
    );

    final page = await _fetchWithCache(
      signature: signature,
      mode: mode,
      request: () async {
        final decoded = await _client.getJson(
          '${ApiConfig.apiV2}$path',
          token: token,
          query: {
            'user_id': authorId,
            'post_collection_id': collectionId,
            'per_page': perPage.toString(),
            'last_id': lastId,
          },
        );
        return extractMapList(decoded);
      },
    );
    if (page.cacheMiss) return PageResult.miss<Post>();

    final posts =
        page.rows.map(Post.fromJson).where((p) => p.id.isNotEmpty).toList();
    await VoteOverlay.instance.syncPosts(posts, fromCache: page.fromCache);

    // 语义校验：只有当返回项**明确声明**了别的合集 id 时才判定参数没被采纳。
    // 若这些项根本没带 post_collection_id，则无从校验，按可用处理。
    final declared =
        posts.where((p) => p.postCollectionId.isNotEmpty).toList();
    final looksRight =
        declared.isEmpty || declared.any((p) => p.postCollectionId == collectionId);
    if (!looksRight) {
      log.e(
        LogTag.fav,
        '合集过滤参数疑似被忽略：合集 $collectionId 返回的 '
        '${declared.length} 条都不属于它',
      );
      throw ApiException(
        ApiErrorKind.decode,
        '服务端似乎忽略了合集过滤参数：返回的 ${declared.length} 条动态都不属于该合集。\n'
        '当前取数口径：api/v2/$path（user_id + post_collection_id）。',
      );
    }

    return _buildPage(page, posts, perPage);
  }

  /// 探测全部失败时的统一报错，带上试过哪些候选，便于排查。
  ApiException _probeFailure(Object? cause, String what, String tried) {
    final reason = cause is ApiException ? cause.message : null;
    return ApiException(
      cause is ApiException ? cause.kind : ApiErrorKind.unknown,
      reason == null
          ? '$what不可用：已尝试 $tried，均未取到数据。'
          : '$what不可用（$reason）\n已尝试：$tried',
      statusCode: cause is ApiException ? cause.statusCode : null,
      uri: cause is ApiException ? cause.uri : null,
    );
  }

  /// 当前登录用户。
  Future<SimpleUser?> fetchCurrentUser({required String token}) async {    final decoded = await _client.getJson(
      '${ApiConfig.apiV2}current_user',
      token: token,
    );
    final map = extractMap(decoded);
    if (map == null) return null;
    if (map['nickname'] == null && map['id'] == null) return null;
    return SimpleUser.fromJson(map);
  }

  /// 点赞 / 取消点赞 / 带一个具体表态点赞。
  ///
  /// 契约来自《点赞状态承载能力-探查报告.md》第一节（逐步读回校验过的矩阵）：
  ///
  /// * **点赞走 v3**：`POST api/v3/votes {post_id[, vote_type]}` → 201。
  ///   必须 v3 —— v2 会**静默忽略** `vote_type`（矩阵第 2 步），你以为送出了
  ///   "安慰"，服务端记的还是普通赞。
  /// * **不带 `vote_type` 的 v3 点赞 = 复位成普通赞**（第 5 步）。这一条很
  ///   重要：服务端取消是"软删"（第 10 步），取消后再点赞会把上一次的状态
  ///   带回来；只有 v3 不带参数才能真的回到普通赞。
  /// * **取消仍走 v2**：`DELETE api/v2/votes {post_id}` → 201。实测 v3 建的
  ///   状态用 v2 删得掉（报告第一节"兼容"条），没必要多一条 v3 路径。
  /// * `vote_type` 是服务端白名单，非法值 400 且**不改动原状态**。所以
  ///   [voteType] 只传 [VoteStates.all] 里的 id；[VoteStates.plain] 等同
  ///   "不传"（那个字面值没实测过，别拿去当参数）。
  Future<void> vote({
    required String postId,
    required bool on,
    required String token,
    String? voteType,
  }) async {
    if (!on) {
      await _client.sendJson(
        'DELETE',
        '${ApiConfig.apiV2}votes',
        token: token,
        body: {'post_id': postId},
      );
      return;
    }

    final state =
        (voteType == null || voteType == VoteStates.plain) ? null : voteType;
    await _client.sendJson(
      'POST',
      '${ApiConfig.apiV3}votes',
      token: token,
      body: {
        'post_id': postId,
        if (state != null) 'vote_type': state,
      },
    );
  }

  /// 收藏 / 取消收藏。
  Future<void> favourite({
    required String postId,
    required bool on,
    required String token,
  }) async {
    await _client.sendJson(
      on ? 'POST' : 'DELETE',
      '${ApiConfig.apiV2}favourites',
      token: token,
      body: {'post_id': postId},
    );
  }

  /// 关注 / 取关他人。
  ///
  /// 端点与参数已实测（《关注按钮与评论图片与取消收藏跳动-探查报告.md》第 1 节）：
  /// `POST api/v2/follows` body `{user_id}` → 201、`DELETE api/v2/follows?user_id=`
  /// → 200，两者响应体都是被关注用户的资料对象（本方法不消费）。
  ///
  /// ⚠️ 服务端**不拒绝自关注**（对自己的 id 也返回 201）→ 自己的主页必须由
  /// 客户端隐藏入口，不能指望服务端拦。
  Future<void> follow({
    required String userId,
    required bool on,
    required String token,
  }) async {
    await _client.sendJson(
      on ? 'POST' : 'DELETE',
      '${ApiConfig.apiV2}follows',
      token: token,
      body: on ? {'user_id': userId} : null,
      query: on ? null : {'user_id': userId},
    );
  }

  /// 评论列表。
  Future<PageResult<Comment>> fetchComments({
    required String postId,
    required String token,
    String lastId = '',
    int perPage = ApiConfig.defaultPerPage,
    CacheMode mode = CacheMode.preferCache,
  }) {
    final signature = CacheKey.comments(
      postId: postId,
      lastId: lastId,
      perPage: perPage,
    );
    return _fetchWithCache(
      signature: signature,
      mode: mode,
      request: () async {
        final decoded = await _client.getJson(
          '${ApiConfig.apiV2}comments',
          token: token,
          query: {
            'post_id': postId,
            'per_page': perPage.toString(),
            'last_id': lastId,
          },
        );
        return extractMapList(decoded);
      },
    ).then((page) async {
      if (page.cacheMiss) return PageResult.miss<Comment>();
      final comments =
          page.rows.map(Comment.fromJson).where((c) => c.id.isNotEmpty).toList();
      // 缓存来源套用本地点赞覆盖层；网络来源对账（服务端为准）。
      await VoteOverlay.instance.syncComments(comments,
          fromCache: page.fromCache);
      return _buildPage(page, comments, perPage);
    });
  }

  /// 某条评论的回复列表（GET api/v2/comments/replies）。
  ///
  /// 2026-09-16 实测该端点存在（同路径 POST 是"发回复"），
  /// 修正了"没有单独回复列表端点"的旧结论。评论项内嵌的
  /// `preview_replies` 通常只有前 3 条，看全靠这里翻页。
  ///
  /// 注意行为差异：对**不存在**的 comment_id 返回 **空数组（200）**，
  /// 与写端点的 4xx/500 行为不一致，按"空即无"处理即可。
  Future<PageResult<Comment>> fetchCommentReplies({
    required String commentId,
    required String token,
    String lastId = '',
    int perPage = ApiConfig.defaultPerPage,
    CacheMode mode = CacheMode.preferCache,
  }) {
    final signature = CacheKey.commentReplies(
      commentId: commentId,
      lastId: lastId,
      perPage: perPage,
    );
    return _fetchWithCache(
      signature: signature,
      mode: mode,
      request: () async {
        final decoded = await _client.getJson(
          '${ApiConfig.apiV2}comments/replies',
          token: token,
          query: {
            'comment_id': commentId,
            'per_page': perPage.toString(),
            'last_id': lastId,
          },
        );
        return extractMapList(decoded);
      },
    ).then((page) async {
      if (page.cacheMiss) return PageResult.miss<Comment>();
      final comments =
          page.rows.map(Comment.fromJson).where((c) => c.id.isNotEmpty).toList();
      // 缓存来源套用本地点赞覆盖层；网络来源对账（服务端为准）。
      await VoteOverlay.instance.syncComments(comments,
          fromCache: page.fromCache);
      return _buildPage(page, comments, perPage);
    });
  }

  /// 发表评论。
  ///
  /// [media] 是随评论一起发送的表情/图片（官方形态：media 数组项 =
  /// `{type:"image", url}`，非空才带 media 键）。**评论里的表情不是文本**，
  /// 不往 content 里插图片链接。
  Future<void> createComment({
    required String postId,
    required String content,
    List<Emoji> media = const [],
    required String token,
  }) async {
    await _client.sendJson(
      'POST',
      '${ApiConfig.apiV2}comments',
      token: token,
      body: _commentBody(content, media, {'post_id': postId}),
    );
  }

  /// 回复评论 / 回复楼层。
  ///
  /// [commentId] 传目标评论（或回复楼层）的 id——对回复楼层再回复
  /// （楼中楼）同样走这里，服务端平铺一层、用 `replied_user` 表达对象。
  Future<void> replyComment({
    required String commentId,
    required String content,
    List<Emoji> media = const [],
    required String token,
  }) async {
    await _client.sendJson(
      'POST',
      '${ApiConfig.apiV2}comments/replies',
      token: token,
      body: _commentBody(content, media, {'comment_id': commentId}),
    );
  }

  /// 评论 body 组装：正文 + 目标 + 表情 media。
  ///
  /// media 项按官方产物 `bMX()` 的形态只带 type 与 url（宽高服务端自补）。
  Map<String, dynamic> _commentBody(
    String content,
    List<Emoji> media,
    Map<String, dynamic> target,
  ) {
    final body = <String, dynamic>{
      ...target,
      'content': content,
    };
    if (media.isNotEmpty) {
      body['media'] = [
        for (final e in media)
          {'type': 'image', 'url': e.url},
      ];
    }
    return body;
  }

  /// 评论点赞 / 取消（POST|DELETE api/v2/comment_votes，body {comment_id}）。
  ///
  /// 主楼与回复楼层都是评论，同一端点通用。已实测：他人评论同样可赞。
  ///
  /// 两个反直觉行为（探查报告第六节）：
  /// * 对**不存在**的 comment_id，DELETE 会返回 **500**（Rails 未捕获异常）
  ///   ——500 在这里等于"资源不存在"，不是端点坏；
  /// * 评论对象只在 `is_owner=true` 时带 `votes_count`，他人评论拿不到计数。
  Future<void> commentVote({
    required String commentId,
    required bool on,
    required String token,
  }) async {
    await _client.sendJson(
      on ? 'POST' : 'DELETE',
      '${ApiConfig.apiV2}comment_votes',
      token: token,
      body: {'comment_id': commentId},
    );
  }

  /// 校验 token 连通性。
  Future<bool> verifyToken(String token) => _client.ping(token: token);

  // ------------------------------------------------------------ 他人主页

  /// 用户主页头部（GET api/v2/users/{id}）。
  ///
  /// 返回对外字段 + 与当前登录用户的关系态（is_following / is_follower /
  /// is_friend / is_muted / is_blocked）。**注意服务端的静默忽略陷阱**：
  /// `user_badges` 与 `follows/followers|followings` 的 `user_id` 参数会被
  /// 服务端忽略、永远返回"我的"，所以粉丝/关注列表在这里做不了，
  /// 只能用本接口的关系态布尔值。
  Future<UserProfile?> fetchUserProfile({
    required String token,
    required String userId,
  }) async {
    if (userId.isEmpty) return null;
    final decoded = await _client.getJson(
      '${ApiConfig.apiV2}users/$userId',
      token: token,
    );
    final map = extractMap(decoded);
    if (map == null) return null;
    if (map['id'] == null && map['nickname'] == null) return null;
    return UserProfile.fromJson(map);
  }

  /// 某用户的公开动态流（GET api/v2/posts/profile?user_id=）。
  ///
  /// 与合集内容同端点，但**不带** `post_collection_id` —— 少传参数即可，
  /// 不需要单独的"用户动态"端点（`users/{id}/posts` 不存在，Rails HTML 404）。
  Future<PageResult<Post>> fetchUserPosts({
    required String token,
    required String userId,
    String lastId = '',
    int perPage = ApiConfig.defaultPerPage,
    CacheMode mode = CacheMode.preferCache,
  }) async {
    final signature = CacheKey.userPosts(
      userId: userId,
      lastId: lastId,
      perPage: perPage,
    );
    final page = await _fetchWithCache(
      signature: signature,
      mode: mode,
      request: () async {
        final decoded = await _client.getJson(
          '${ApiConfig.apiV2}posts/profile',
          token: token,
          query: {
            'user_id': userId,
            'per_page': perPage.toString(),
            'last_id': lastId,
          },
        );
        return extractMapList(decoded);
      },
    );
    if (page.cacheMiss) return PageResult.miss<Post>();
    final posts =
        page.rows.map(Post.fromJson).where((p) => p.id.isNotEmpty).toList();
    // 缓存来源套用本地点赞覆盖层；网络来源对账（服务端为准）。
    await VoteOverlay.instance.syncPosts(posts, fromCache: page.fromCache);
    return _buildPage(page, posts, perPage);
  }

  // ---------------------------------------------------------------- 表情包

  /// 系统表情包列表（GET api/v2/emojis/packages → [{id, name, icon}]）。
  Future<List<EmojiPackage>> fetchEmojiPackages({required String token}) async {
    final decoded = await _client.getJson(
      '${ApiConfig.apiV2}emojis/packages',
      token: token,
    );
    final rows = extractMapList(decoded);
    return rows.map(EmojiPackage.fromJson).where((e) => e.id.isNotEmpty).toList();
  }

  /// 某个系统包内的表情（GET api/v2/emojis?package_emoji_id= → [{id, url}]）。
  ///
  /// `package_emoji_id` 是必填参数：缺参会 400 `package_emoji_id is missing`。
  Future<List<Emoji>> fetchEmojis({
    required String token,
    required String packageEmojiId,
  }) async {
    final decoded = await _client.getJson(
      '${ApiConfig.apiV2}emojis',
      token: token,
      query: {'package_emoji_id': packageEmojiId},
    );
    final rows = extractMapList(decoded);
    return rows.map(Emoji.fromJson).where((e) => e.url.isNotEmpty).toList();
  }

  /// 当前登录用户的表情（GET api/v2/emojis/favorites → [{id, url}]）。
  ///
  /// 就是"我的表情"：官方表情面板的「收藏」tab 用的这份账号级数据。
  Future<List<Emoji>> fetchEmojiFavorites({required String token}) async {
    final decoded = await _client.getJson(
      '${ApiConfig.apiV2}emojis/favorites',
      token: token,
    );
    final rows = extractMapList(decoded);
    return rows.map(Emoji.fromJson).where((e) => e.url.isNotEmpty).toList();
  }

  /// 收藏 / 取消收藏表情。
  ///
  /// 两个方向的参数名不同（实测钉死）：收藏是 `{user_emoji_id}`，
  /// 取消是 `{ids:[…]}` —— 传错会 400 `ids is missing`。
  Future<void> setEmojiFavorite({
    required String userEmojiId,
    required bool on,
    required String token,
  }) async {
    if (on) {
      await _client.sendJson(
        'POST',
        '${ApiConfig.apiV2}emojis/favorite',
        token: token,
        body: {'user_emoji_id': userEmojiId},
      );
    } else {
      await _client.sendJson(
        'DELETE',
        '${ApiConfig.apiV2}emojis/favorite',
        token: token,
        body: {'ids': [userEmojiId]},
      );
    }
  }

  // ------------------------------------------------------------------ 工具

  /// 游标推进：下一页游标 = 本页最后一条的 `id`。
  PageResult<T> _buildPage<T>(
    _RawPage page,
    List<T> items,
    int perPage,
  ) {
    final rows = page.rows;
    final hasMore = rows.length >= perPage;
    String? cursor;
    if (hasMore && rows.isNotEmpty) {
      final id = rows.last['id'];
      if (id != null && id.toString().isNotEmpty) cursor = id.toString();
    }
    return PageResult<T>(
      items: items,
      nextCursor: cursor,
      hasMore: hasMore && cursor != null,
      fromCache: page.fromCache,
      cachedAt: page.cachedAt,
    );
  }
}
