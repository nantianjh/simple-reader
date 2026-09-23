import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/models.dart';
import '../util/app_log.dart';
import 'local_store.dart';

/// 本机收藏夹里的一条合集记录。
///
/// 服务端**没有**「我收藏的合集」汇总端点（探查报告 9.6：`user_id` 的语义是
/// 「合集作者」，19 个收藏关系参数全部被静默忽略），因此这份列表只能本地自建：
/// 从「已收藏的动态」里把内嵌的 `post_collection` 解析出来累积。
///
/// [authorId] 是查询合集内容所必需的 —— 合集内容只有
/// `posts/profile?user_id=<作者>&post_collection_id=<合集>` 认这个过滤参数，
/// 而内嵌的合集对象本身不一定带 `user_id`（v2 只有 4 个字段），
/// 所以这里固定记下动态作者，作为合集作者的来源。
class FavCollection {
  const FavCollection({
    required this.id,
    required this.name,
    required this.description,
    required this.coverUrl,
    required this.authorId,
    required this.authorName,
    required this.postsCount,
    required this.addedAt,
    required this.lastSeenAt,
    this.sourcePostId = '',
    this.subscribed = false,
    this.hasNew = false,
    this.lastSeenTopPostId = '',
  });

  final String id;
  final String name;
  final String description;
  final String coverUrl;

  /// 合集作者 ID。查询合集内容必需。
  final String authorId;

  /// 合集作者昵称，仅用于展示。
  final String authorName;

  /// 合集内条数。解析来源不提供时记 -1（UI 不展示条数）。
  final int postsCount;

  /// 首次进入本机收藏夹的时间。列表按它倒序，保证顺序稳定。
  final DateTime addedAt;

  /// 最近一次在收藏动态里被解析到的时间。
  final DateTime lastSeenAt;

  /// 触发收录的那条动态 id，便于排查。
  final String sourcePostId;

  /// 是否已订阅。订阅后冷启动时会串行扫描该合集内有无新动态。
  final bool subscribed;

  /// 扫描发现新动态后的红点标记；用户点开该合集后清除。
  final bool hasNew;

  /// 最近一次「看过 / 扫描基线」的合集首条（最新）动态 id。
  ///
  /// 扫描时拿合集最新一条的 id 与它对比：不同即有新动态；
  /// 为空表示从未建立基线（首次扫描只记基线、不标新）。
  final String lastSeenTopPostId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'coverUrl': coverUrl,
        'authorId': authorId,
        'authorName': authorName,
        'postsCount': postsCount,
        'addedAt': addedAt.millisecondsSinceEpoch,
        'lastSeenAt': lastSeenAt.millisecondsSinceEpoch,
        'sourcePostId': sourcePostId,
        'subscribed': subscribed,
        'hasNew': hasNew,
        'lastSeenTopPostId': lastSeenTopPostId,
      };

  static FavCollection? fromJson(Map<String, dynamic> m) {
    final id = m['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    DateTime time(dynamic v) => v is num
        ? DateTime.fromMillisecondsSinceEpoch(v.toInt())
        : DateTime.now();
    final count = m['postsCount'];
    return FavCollection(
      id: id,
      name: m['name']?.toString() ?? '',
      description: m['description']?.toString() ?? '',
      coverUrl: m['coverUrl']?.toString() ?? '',
      authorId: m['authorId']?.toString() ?? '',
      authorName: m['authorName']?.toString() ?? '',
      postsCount: count is num ? count.toInt() : -1,
      addedAt: time(m['addedAt']),
      lastSeenAt: time(m['lastSeenAt']),
      sourcePostId: m['sourcePostId']?.toString() ?? '',
      subscribed: m['subscribed'] == true,
      hasNew: m['hasNew'] == true,
      lastSeenTopPostId: m['lastSeenTopPostId']?.toString() ?? '',
    );
  }

  /// 转成合集详情页需要的 [PostCollection]。
  ///
  /// 本机记录里没有 `visibility` / `created_at`（内嵌对象给不全），
  /// 这几项留空即可 —— 详情页只把它们当展示兜底。
  PostCollection asCollection() => PostCollection(
        id: id,
        name: name.isEmpty ? '未命名合集' : name,
        visibility: '',
        userId: authorId,
        description: description,
        coverUrl: coverUrl,
        postsCount: postsCount,
        // 本机收录不代表官方端"已收藏该合集"，这里不臆造收藏态；
        // 真实状态由详情页拉 v3 单条接口时回填。
        isFavourited: false,
        createdAt: null,
        creator: authorName.isEmpty
            ? SimpleUser.empty
            : SimpleUser(
                id: authorId,
                nickname: authorName,
                gender: '',
                avatarUrl: '',
                avatarColor: '',
                isOfficial: false,
                isPrivacyEnabled: false,
                isNewUser: false,
              ),
      );

  FavCollection copyWith({
    String? name,
    String? description,
    String? coverUrl,
    String? authorId,
    String? authorName,
    int? postsCount,
    DateTime? lastSeenAt,
    String? sourcePostId,
    bool? subscribed,
    bool? hasNew,
    String? lastSeenTopPostId,
  }) =>
      FavCollection(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        coverUrl: coverUrl ?? this.coverUrl,
        authorId: authorId ?? this.authorId,
        authorName: authorName ?? this.authorName,
        postsCount: postsCount ?? this.postsCount,
        addedAt: addedAt,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        sourcePostId: sourcePostId ?? this.sourcePostId,
        subscribed: subscribed ?? this.subscribed,
        hasNew: hasNew ?? this.hasNew,
        lastSeenTopPostId: lastSeenTopPostId ?? this.lastSeenTopPostId,
      );
}

/// 本机自建的「收藏的合集」仓库。
///
/// 三条不可违反的约束（均来自《合集与收藏API-探查报告》第九节）：
/// 1. 服务端没有汇总端点 → 只能本地自建；
/// 2. 服务端没有写入端点 → 本地增删**只影响本机**，官方端状态不变；
/// 3. 由于（2），若删除只从列表里摘掉，下一次同步立刻会把它解析回来，
///    删除就形同虚设 —— 因此删除会记入 [removedIds] 墓碑集合，
///    同步时跳过被删过的 id，直到用户主动恢复。
class FavouriteCollectionsStore extends ChangeNotifier {
  FavouriteCollectionsStore._();

  static final FavouriteCollectionsStore instance =
      FavouriteCollectionsStore._();

  final Map<String, FavCollection> _items = <String, FavCollection>{};
  final Set<String> _removed = <String>{};

  /// 是否已经做过「首次自动完整同步」。
  ///
  /// 语义：本机目录还什么都没有的时候，只抓最新一页收藏动态往往解析不出任何
  /// 合集（历史收藏里的合集都在更早的页），用户看到的就是"收藏夹一直是空的"。
  /// 因此首次进入会自动翻遍全部收藏动态一次，并把这件事持久化下来，
  /// 避免每次冷启动都重跑一遍全量。清空本机目录时会重置（相当于回到首次）。
  bool _autoFullSynced = false;

  /// 最近一次同步新增（此前不在本机库中）的合集 id。
  final Set<String> _lastAdded = <String>{};

  bool _loaded = false;

  bool get loaded => _loaded;

  bool get autoFullSynced => _autoFullSynced;

  /// 按收录时间倒序（新收录的在前），顺序稳定不随浏览跳动。
  List<FavCollection> get items {
    final list = _items.values.toList()
      ..sort((a, b) {
        final c = b.addedAt.compareTo(a.addedAt);
        return c != 0 ? c : a.name.compareTo(b.name);
      });
    return List<FavCollection>.unmodifiable(list);
  }

  int get length => _items.length;

  /// 被本机删除过的合集数量。
  int get removedCount => _removed.length;

  /// 上一次同步新收录的合集 id，供 UI 高亮。
  Set<String> get lastAddedIds => Set<String>.unmodifiable(_lastAdded);

  bool contains(String id) => _items.containsKey(id);

  FavCollection? byId(String id) => _items[id];

  /// 元信息不全（缺名称或条数）的条目 id，供上层用 v3 单条接口补齐。
  ///
  /// 出现在这里的是"服务端没给内嵌合集对象、只能靠 `post_collection_id`
  /// 兜底收录"的条目 —— 典型即 `visibility = collection_visibility` 的合集。
  List<String> get idsMissingMeta => _items.values
      .where((e) => e.name.isEmpty || e.postsCount < 0)
      .map((e) => e.id)
      .toList();

  // -------------------------------------------------------------- 订阅扫描

  /// 已订阅的合集（冷启动扫描的对象）。
  List<FavCollection> get subscribedItems =>
      _items.values.where((e) => e.subscribed).toList();

  /// 设置 / 取消订阅。取消时一并清掉红点，避免残留过期提示。
  Future<void> setSubscribed(String id, bool value) async {
    final old = _items[id];
    if (old == null) return;
    if (old.subscribed == value && (!value || !old.hasNew)) return;
    _items[id] = old.copyWith(subscribed: value, hasNew: value && old.hasNew);
    log.i(
      LogTag.fav,
      '${value ? '订阅' : '取消订阅'}合集：${old.name}（$id）',
    );
    notifyListeners();
    await _persist();
  }

  /// 回写一次订阅扫描结果。
  ///
  /// * 基线（[FavCollection.lastSeenTopPostId]）为空 → 首次扫描只记基线，
  ///   不标新：否则"刚订阅就满屏红点"，没有信息量；
  /// * 基线非空 → 与合集最新一条动态 id 对比，不同即标红点。
  Future<void> applyScan(String id, String topPostId) async {
    if (topPostId.isEmpty) return;
    final old = _items[id];
    if (old == null || !old.subscribed) return;
    if (old.lastSeenTopPostId.isEmpty) {
      _items[id] = old.copyWith(lastSeenTopPostId: topPostId);
      log.d(LogTag.fav, '订阅扫描建立基线：$id → $topPostId');
      await _persist();
      return;
    }
    final hasNew = topPostId != old.lastSeenTopPostId;
    if (hasNew == old.hasNew) return; // 状态没变，不重画不落盘
    _items[id] = old.copyWith(hasNew: hasNew);
    log.i(
      LogTag.fav,
      '订阅扫描${hasNew ? '发现新动态' : '无新动态'}：${old.name}（$id）',
    );
    notifyListeners();
    await _persist();
  }

  /// 用户点开了该合集：红点清除，基线推进到当前最新一条。
  Future<void> markSeen(String id, String topPostId) async {
    final old = _items[id];
    if (old == null) return;
    if (!old.hasNew && old.lastSeenTopPostId == topPostId) return;
    _items[id] = old.copyWith(hasNew: false, lastSeenTopPostId: topPostId);
    notifyListeners();
    await _persist();
  }

  /// 从本地存储载入。数据损坏时按空库处理，不阻断启动。
  Future<void> load() async {
    _items.clear();
    _removed.clear();
    _autoFullSynced = false;
    final raw = LocalStore.instance.readMap(LocalStore.keyFavCollections);

    final rawItems = raw['items'];
    if (rawItems is Map) {
      rawItems.forEach((k, v) {
        if (v is! Map) return;
        final e = FavCollection.fromJson(
          v.map((key, value) => MapEntry(key.toString(), value)),
        );
        if (e != null) _items[e.id] = e;
      });
    }
    final rawRemoved = raw['removed'];
    if (rawRemoved is List) {
      for (final v in rawRemoved) {
        final id = v?.toString() ?? '';
        if (id.isNotEmpty) _removed.add(id);
      }
    }
    _autoFullSynced = raw['autoFullSynced'] == true;
    _loaded = true;
  }

  /// 从磁盘整体重载并通知监听者（数据导入后调用）。
  ///
  /// 与 [load] 的区别只有一个：这里会 `notifyListeners()`。启动时的 [load]
  /// 不需要通知（UI 还没挂载），而导入是运行期发生的，不通知的话合集页
  /// 仍显示导入前的按钮墙。
  Future<void> reloadFromDisk() async {
    await load();
    notifyListeners();
  }

  /// 标记「首次自动完整同步」已完成，避免下次冷启动再跑一遍。
  Future<void> markAutoFullSynced() async {
    if (_autoFullSynced) return;
    _autoFullSynced = true;
    await _persist();
  }

  /// 用一批「已收藏的动态」解析并累积合集。
  ///
  /// 返回本次**新收录**的条数。被本机删除过的合集不参与收录；
  /// 已存在的条目只更新元信息（名称/简介/条数/作者），不改变收录时间。
  ///
  /// 「新收录」标记是**累加**的：一次完整同步会逐页调用本方法，
  /// 标记要覆盖整轮解析的结果（清空动作由调用方在同步开始时做）。
  int absorbFromPosts(List<Post> posts) {
    final now = DateTime.now();
    final added = <String>{};
    var changed = false;

    for (final post in posts) {
      // 合集对象**未必内嵌**，不能用它作为收录前提。
      //
      // 实测（2026-09-15）：`visibility = collection_visibility` 的合集，
      // 服务端在动态的 `post_collection` 字段上**整键省略** —— 不是给 null，
      // 而是这个键根本不存在，只留 `post_collection_id`。同类可见性的两条
      // 命中率 2/2，而 public_visibility 的 8 条 8/8 都带完整对象。
      // 单条接口 `GET api/v2/posts/{id}` 对这类动态同样不给该键。
      //
      // 旧实现只认 `post.postCollection`，遇到这类动态直接 continue，
      // 于是这类合集即使已被收藏、动态也确在收藏列表里，也永远进不了本机库
      // —— 这正是"有的合集能解析、有的不能"的原因。这里改为允许"只有 id"，
      // 名称等元信息随后用 v3 单条接口补（见 `CollectionsController` 的补全步骤）。
      final embedded = post.postCollection;
      final id = (embedded != null && embedded.id.isNotEmpty)
          ? embedded.id
          : post.postCollectionId;
      if (id.isEmpty) continue;
      if (_removed.contains(id)) continue;

      // 内嵌合集对象不一定带 user_id（v2 只有 4 个字段），
      // 缺失时用动态作者兜底 —— 动态作者即合集作者。
      final authorId = (embedded != null && embedded.userId.isNotEmpty)
          ? embedded.userId
          : post.user.id;
      final authorName = post.user.nickname;

      final old = _items[id];
      if (old == null) {
        _items[id] = FavCollection(
          id: id,
          name: embedded?.name ?? '',
          description: embedded?.description ?? '',
          coverUrl: embedded?.coverUrl ?? '',
          authorId: authorId,
          authorName: authorName,
          // 内嵌对象一般没有 posts_count；等进入合集详情时用 v3 单条接口补全。
          postsCount: embedded?.postsCount ?? -1,
          addedAt: now,
          lastSeenAt: now,
          sourcePostId: post.id,
        );
        added.add(id);
        changed = true;
      } else {
        final updated = old.copyWith(
          name: (embedded != null && embedded.name.isNotEmpty)
              ? embedded.name
              : old.name,
          description: (embedded != null && embedded.description.isNotEmpty)
              ? embedded.description
              : old.description,
          coverUrl: (embedded != null && embedded.coverUrl.isNotEmpty)
              ? embedded.coverUrl
              : old.coverUrl,
          authorId: authorId.isNotEmpty ? authorId : old.authorId,
          authorName: authorName.isNotEmpty ? authorName : old.authorName,
          postsCount: (embedded != null && embedded.postsCount >= 0)
              ? embedded.postsCount
              : old.postsCount,
          lastSeenAt: now,
          sourcePostId: post.id,
        );
        _items[id] = updated;
        changed = true;
      }
    }

    // 标记累加（整轮同步共用一份"新收录"集合）。
    _lastAdded.addAll(added);
    // 旧实现只在「有新收录」时落盘，于是"已存在条目的名称补全"永远写不下去；
    // 这里改为只要库有变化就落盘。
    if (changed) unawaited(_persist());
    return added.length;
  }

  /// 更新一条合集的元信息（进入合集详情、拿到 v3 单条数据后回填）。
  Future<void> updateMeta({
    required String id,
    String? name,
    String? description,
    int? postsCount,
    String? authorId,
  }) async {
    final old = _items[id];
    if (old == null) return;
    _items[id] = old.copyWith(
      name: name,
      description: description,
      postsCount: postsCount,
      authorId: authorId,
    );
    notifyListeners();
    await _persist();
  }

  /// 从本机收藏夹移除一条（只影响本机；同时记入墓碑，避免下次同步又冒出来）。
  Future<void> remove(String id) async {
    if (id.isEmpty) return;
    final existed = _items.remove(id) != null;
    final tombstoned = _removed.add(id);
    _lastAdded.remove(id);
    if (!existed && !tombstoned) return;
    notifyListeners();
    await _persist();
  }

  /// 恢复所有被本机删除过的合集。
  ///
  /// 恢复后它们不会立刻出现 —— 需要下一次同步（进入收藏夹页）重新解析到才会回来，
  /// 这与「列表由收藏动态驱动」的口径一致。
  Future<void> restoreRemoved() async {
    if (_removed.isEmpty) return;
    _removed.clear();
    notifyListeners();
    await _persist();
  }

  /// 清空本机收藏夹（含墓碑）。
  ///
  /// 同时重置「首次自动完整同步」标记：清空等于回到"什么都没有"的初始状态，
  /// 下一次进入应该重新翻遍收藏动态把目录建起来。
  Future<void> clear() async {
    if (_items.isEmpty && _removed.isEmpty && !_autoFullSynced) return;
    _items.clear();
    _removed.clear();
    _lastAdded.clear();
    _autoFullSynced = false;
    notifyListeners();
    await _persist();
  }

  /// 清掉「新收录」标记（UI 高亮过一次后调用）。
  void clearLastAdded() {
    if (_lastAdded.isEmpty) return;
    _lastAdded.clear();
    notifyListeners();
  }

  /// 是否还没有任何收录条目（用于判断「初次建立」）。
  bool get isEmpty => _items.isEmpty;

  Future<void> _persist() => LocalStore.instance.write(
        LocalStore.keyFavCollections,
        {
          'items': _items.map((k, v) => MapEntry(k, v.toJson())),
          'removed': _removed.toList(),
          'autoFullSynced': _autoFullSynced,
        },
      );
}
