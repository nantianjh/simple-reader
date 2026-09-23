/// 服务端返回对象的容错解析。
///
/// 契约第四节列出的内容帖对象共 22 个字段；字段可能缺失、类型可能漂移
/// （例如 `comments_count` 偶尔为字符串），因此一律走容错取值，
/// 保证任何单条脏数据不会让整页解析失败。
library;

import 'api_config.dart';

String? asStringOrNull(dynamic v) {
  if (v == null) return null;
  if (v is String) return v;
  return v.toString();
}

String asString(dynamic v, [String fallback = '']) {
  final s = asStringOrNull(v);
  if (s == null || s.isEmpty) return fallback;
  return s;
}

int asInt(dynamic v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? fallback;
  return fallback;
}

bool asBool(dynamic v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.toLowerCase().trim();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
  }
  return fallback;
}

DateTime? asDateTime(dynamic v) {
  if (v is DateTime) return v;
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
  if (v is int) {
    // 秒 / 毫秒时间戳兜底。
    final ms = v > 1000000000000 ? v : v * 1000;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }
  return null;
}

Map<String, dynamic> asMap(dynamic v) {
  if (v is Map) return v.map((k, value) => MapEntry(k.toString(), value));
  return const <String, dynamic>{};
}

/// 作者信息。
class SimpleUser {
  const SimpleUser({
    required this.id,
    required this.nickname,
    required this.gender,
    required this.avatarUrl,
    required this.avatarColor,
    required this.isOfficial,
    required this.isPrivacyEnabled,
    required this.isNewUser,
  });

  final String id;
  final String nickname;
  final String gender;
  final String avatarUrl;
  final String avatarColor;
  final bool isOfficial;
  final bool isPrivacyEnabled;
  final bool isNewUser;

  static const SimpleUser empty = SimpleUser(
    id: '',
    nickname: '未知用户',
    gender: '',
    avatarUrl: '',
    avatarColor: '',
    isOfficial: false,
    isPrivacyEnabled: false,
    isNewUser: false,
  );

  factory SimpleUser.fromJson(Map<String, dynamic> j) => SimpleUser(
        id: asString(j['id']),
        nickname: asString(j['nickname'], '未知用户'),
        gender: asString(j['gender']),
        avatarUrl: asString(j['avatar_url']),
        avatarColor: asString(j['avatar_color']),
        isOfficial: asBool(j['is_official']),
        isPrivacyEnabled: asBool(j['is_privacy_enabled']),
        isNewUser: asBool(j['is_new_user']),
      );

  /// 头像底色，形如 `dacff7`，用于无头像时生成占位。
  int? get avatarColorValue {
    if (avatarColor.isEmpty) return null;
    final hex = avatarColor.replaceFirst('#', '');
    if (hex.length != 6) return null;
    return int.tryParse('FF$hex', radix: 16);
  }
}

/// 媒体附件（图片 / 视频 / 音频 / 链接卡片）。
///
/// 服务端的 `type` 取值没有在契约里穷举，实际会漂移（例如实况照片既可能
/// 标成 `live`，也可能只给一个 `.mov` / `.heic` 地址）。因此这里不依赖
/// 单一字段，而是「type + 扩展名」联合判定，并把无法解码的媒体归到
/// 「实况图片」占位，避免列表里出现一片破图。
class MediaItem {
  const MediaItem({
    required this.url,
    required this.type,
    required this.width,
    required this.height,
    this.raw = const <String, dynamic>{},
  });

  final String url;
  final String type;
  final int width;
  final int height;

  /// 原始 JSON，用于取契约未覆盖的可选字段（如链接卡片的原始地址）。
  final Map<String, dynamic> raw;

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
        url: asString(j['url']),
        type: asString(j['type']),
        width: asInt(j['width']),
        height: asInt(j['height']),
        raw: j,
      );

  /// 可解码的静态图片扩展名。`heic` / `heif` / `avif` 不在其中：
  /// Flutter 的图像解码链路在多数 Android 设备上解不开，会退化成破图。
  static const Set<String> _imageExts = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
  };

  /// Flutter 无法直接解码、但可尝试经七牛 `format/jpg` 转码后显示的扩展名
  /// （实况照片的静态帧通常是 heic/heif）。
  static const Set<String> _transcodableImageExts = {
    'heic',
    'heif',
    'avif',
  };

  static const Set<String> _videoExts = {
    'mp4',
    'mov',
    'm4v',
    'avi',
    'mkv',
    'webm',
    '3gp',
  };

  static const Set<String> _audioExts = {
    'mp3',
    'm4a',
    'aac',
    'wav',
    'flac',
    'ogg',
    'amr',
  };

  /// URL 上的文件扩展名（小写，已剥离 query / fragment）。取不到时为空串。
  String get fileExtension {
    var s = url;
    final q = s.indexOf('?');
    if (q >= 0) s = s.substring(0, q);
    final h = s.indexOf('#');
    if (h >= 0) s = s.substring(0, h);
    final slash = s.lastIndexOf('/');
    if (slash >= 0) s = s.substring(slash + 1);
    final dot = s.lastIndexOf('.');
    if (dot < 0 || dot == s.length - 1) return '';
    final ext = s.substring(dot + 1).toLowerCase();
    // 扩展名不可能太长，过长说明这个「点」不是扩展名分隔符。
    if (ext.length > 5 || ext.contains('.')) return '';
    return ext;
  }

  String get _lowerType => type.toLowerCase();

  /// `type` 明确声明为实况照片（live / motion）。
  ///
  /// 实况照片的媒体地址常带 `.mov`（视频帧）或 `.heic`（静态帧）扩展名，
  /// 若只看扩展名会被误判成视频。只要 type 声明了 live，一律按实况照片
  /// 处理，不再落进视频分支。
  bool get typeSaysLivePhoto {
    if (_lowerType.contains('live') || _lowerType.contains('motion')) {
      return true;
    }
    return asBool(raw['is_live_photo']) || asBool(raw['live_photo']);
  }

  bool get isVideo =>
      !typeSaysLivePhoto &&
      (_lowerType.contains('video') || _videoExts.contains(fileExtension));

  bool get isAudio =>
      _lowerType.contains('audio') || _audioExts.contains(fileExtension);

  /// 能否交给图片查看器渲染。
  ///
  /// 有扩展名时以扩展名白名单为准；没有扩展名时（七牛处理过的地址常见）
  /// 退回到 `type` 前缀判断。
  bool get isDecodableImage {
    if (isVideo || isAudio) return false;
    final ext = fileExtension;
    if (ext.isEmpty) {
      final t = _lowerType;
      return t.isEmpty || t.contains('image') || t.contains('photo');
    }
    return _imageExts.contains(ext);
  }

  /// 「实况图片」及一切无法解码的媒体：列表里显示占位标签，不尝试加载。
  bool get isLivePhoto =>
      !isVideo && !isAudio && !isDecodableImage;

  /// 可经服务端转码后尝试显示的图片（heic/heif/avif）。
  ///
  /// 静态资源在七牛上，`?imageView2/2/format/jpg` 可把这类格式转成 jpg；
  /// 转码失败（服务端不支持该源格式）时由 UI 回落到准确的类型标签。
  bool get isTranscodableImage =>
      !isVideo && !isAudio && _transcodableImageExts.contains(fileExtension);

  /// 转码显示用的 URL：追加 `format/jpg`，已带 query 时按 imageView2 的
  /// 路径式参数继续追加，未带 query 时补全整段缩略参数。
  String get transcodeUrl {
    if (url.contains('?')) {
      return url.endsWith('/') ? url : '$url/format/jpg';
    }
    return '$url?imageView2/2/format/jpg';
  }

  /// 链接卡片形式的附件：服务端把动态里的 URL 转成卡片时会带上原始地址。
  ///
  /// 判定分三级，避免把网页地址误判成「实况照片」：
  /// 1. 显式的 `link_url` / `share_url` / `href` / `link` 字段；
  /// 2. `type` 自报是 link / card / share；
  /// 3. 形态判定：地址是网页型（`.html`/`.php` 之类后缀），
  ///    或**无扩展名又不是静态资源主机上的媒体**（媒体附件通常带
  ///    width/height，网页地址不带）。
  String? get linkUrl {
    for (final k in const ['link_url', 'share_url', 'href', 'link']) {
      final v = raw[k];
      if (v is String && v.startsWith('http')) return v;
    }
    final t = _lowerType;
    if (t.contains('link') || t.contains('card') || t.contains('share')) {
      final v = raw['url'];
      if (v is String && v.startsWith('http')) return v;
    }
    if (looksLikePageUrl) return url;
    return null;
  }

  /// 地址形态更像一个网页而不是媒体文件。
  bool get looksLikePageUrl {
    if (!url.startsWith('http')) return false;
    // type 明确声明了媒体类型时，以 type 为准，不做形态猜测。
    final t = _lowerType;
    if (t.contains('image') ||
        t.contains('photo') ||
        t.contains('video') ||
        t.contains('audio')) {
      return false;
    }
    const pageExts = {
      'html',
      'htm',
      'php',
      'asp',
      'aspx',
      'jsp',
      'do',
      'action',
      'shtml',
    };
    final ext = fileExtension;
    if (pageExts.contains(ext)) return true;
    if (ext.isNotEmpty) return false;
    // 无扩展名：带尺寸的按媒体处理；不带尺寸且不在静态资源主机上的按网页处理。
    if (width > 0 || height > 0) return false;
    return !url.startsWith(ApiConfig.mediaHost);
  }

  bool get isLinkCard => linkUrl != null;

  double get aspectRatio {
    if (width <= 0 || height <= 0) return 3 / 4;
    return width / height;
  }
}

/// 合集（收藏夹）。
///
/// 契约与 Simplexcel 报告都没覆盖合集接口，字段名取自官方 Web 端
/// （Flutter Web 编译产物）对合集的解析：`id` / `name` / `visibility` /
/// `user_id` / `is_favourited`。其余字段按命名习惯容错取值，
/// 拿不到就用安全的默认值，保证列表不会因为缺字段而空白。
class PostCollection {
  const PostCollection({
    required this.id,
    required this.name,
    required this.visibility,
    required this.userId,
    required this.description,
    required this.coverUrl,
    required this.postsCount,
    required this.isFavourited,
    required this.createdAt,
    required this.creator,
    this.raw = const <String, dynamic>{},
  });

  final String id;
  final String name;
  final String visibility;
  final String userId;
  final String description;

  /// 封面图。取不到时列表显示文字占位。
  final String coverUrl;

  /// 合集内动态条数。取不到时返回 -1（UI 不展示条数）。
  final int postsCount;

  /// 是否为我收藏的合集。服务端未提供该字段时为 false。
  final bool isFavourited;

  final DateTime? createdAt;

  /// 合集创建者。列表里用于区分"我的"与他人合集。
  final SimpleUser creator;

  /// 原始 JSON，便于后续补充契约未覆盖的字段。
  final Map<String, dynamic> raw;

  static const PostCollection empty = PostCollection(
    id: '',
    name: '未命名合集',
    visibility: '',
    userId: '',
    description: '',
    coverUrl: '',
    postsCount: -1,
    isFavourited: false,
    createdAt: null,
    creator: SimpleUser.empty,
  );

  factory PostCollection.fromJson(Map<String, dynamic> j) {
    // 条数字段在不同接口里叫法不一，逐一兜底；都没有则记 -1 表示未知。
    int count() {
      for (final k in const [
        'posts_count',
        'post_count',
        'moments_count',
        'moment_count',
        'children_count',
        'items_count',
      ]) {
        final v = j[k];
        if (v is num) return v.toInt();
        if (v is String) {
          final n = int.tryParse(v.trim());
          if (n != null) return n;
        }
      }
      return -1;
    }

    String cover() {
      for (final k in const ['cover_url', 'cover', 'icon', 'image_url']) {
        final v = j[k];
        if (v is String && v.isNotEmpty) return v;
      }
      // 有的实现把封面放在封面图的数组里。
      final medias = j['medias'] ?? j['covers'];
      if (medias is List && medias.isNotEmpty) {
        final first = asMap(medias.first);
        final u = asString(first['url']);
        if (u.isNotEmpty) return u;
      }
      return '';
    }

    final owner = j['user'] ?? j['creator'] ?? j['owner'];

    return PostCollection(
      id: asString(j['id']),
      name: asString(j['name'], asString(j['title'], '未命名合集')),
      visibility: asString(j['visibility']),
      userId: asString(j['user_id']),
      description: asString(j['description']),
      coverUrl: cover(),
      postsCount: count(),
      isFavourited: asBool(j['is_favourited']),
      createdAt: asDateTime(j['created_at']),
      creator: owner is Map ? SimpleUser.fromJson(asMap(owner)) : SimpleUser.empty,
      raw: j,
    );
  }
}

/// 内容帖。字段与契约第四节列出的 22 项一一对应。
class Post {
  Post({
    required this.id,
    required this.raw,
    required this.isTimedPost,
    required this.visibility,
    required this.isPinned,
    required this.commentsCount,
    required this.postType,
    required this.commentPermission,
    required this.createdAt,
    required this.postCollectionId,
    required this.isCollectionPinned,
    required this.isThanked,
    required this.showType,
    required this.content,
    required this.media,
    required this.user,
    required this.isVoted,
    required this.isFavourited,
    required this.isOwner,
    required this.isShow,
    required this.isReviewing,
    required this.postCollection,
  });

  final String id;

  /// 原始 JSON，详情页兜底展示与后续扩展用。
  final Map<String, dynamic> raw;

  final bool isTimedPost;
  final String visibility;
  final bool isPinned;
  final int commentsCount;
  final String postType;
  final String commentPermission;
  final DateTime? createdAt;
  final String postCollectionId;
  final bool isCollectionPinned;
  final bool isThanked;
  final String showType;
  final String content;
  final List<MediaItem> media;
  final SimpleUser user;

  /// 后端返回的点赞态。本地操作后会覆盖。
  bool isVoted;

  /// 后端返回的收藏态（服务端在动态对象里带 `is_favourited`，
  /// 见《合集与收藏API-探查报告.md》第三节实测）。本地操作后会覆盖。
  bool isFavourited;

  final bool isOwner;
  final bool isShow;
  final bool isReviewing;
  final PostCollection? postCollection;

  /// 点赞数。契约未给出该字段，按需从 raw 取，取不到返回 null。
  int? get votesCount {
    for (final k in const ['votes_count', 'vote_count', 'likes_count', 'likes']) {
      final v = raw[k];
      if (v is int) return v;
      if (v is num) return v.toInt();
    }
    return null;
  }

  /// 是否可展示的正文（有些帖仅媒体无文字）。
  bool get hasText => content.trim().isNotEmpty;

  /// 正文之外、由服务端转成「卡片」的链接地址。
  ///
  /// 官方 Web 端会把正文里的 URL 渲染成卡片，此时 `content` 里可能看不到
  /// 原始地址，地址被挪进了 media 或顶层字段。这些地址需要以可点击文本的
  /// 形式补出来，否则用户在客户端完全接触不到链接。
  List<String> get cardLinks {
    final out = <String>[];

    void add(dynamic v) {
      if (v is String && v.startsWith('http') && !out.contains(v)) {
        out.add(v);
      } else if (v is Map) {
        final m = asMap(v);
        for (final k in const ['url', 'link_url', 'href', 'target', 'web_url']) {
          add(m[k]);
        }
      }
    }

    for (final k in const ['link_url', 'share_url', 'link', 'card', 'card_url']) {
      add(raw[k]);
    }
    for (final m in media) {
      if (m.isLinkCard) add(m.linkUrl);
    }
    // 正文里已经能看到的链接不必重复展示。
    return out.where((u) => !content.contains(u)).toList();
  }

  bool get hasCardLinks => cardLinks.isNotEmpty;

  /// 是否处于审核中。
  bool get isPending => isReviewing;

  /// 作者是否关闭了这条动态的评论（服务端 `comment_permission == 'no_comments'`）。
  ///
  /// 只认这一档：它不是"看人下菜"的状态，作者一关谁都不能评，所以凭列表端点
  /// 下发的枚举就能下结论（列表端点**没有** `can_comment`，见
  /// 《动态评论权限状态-探查报告.md》第二节）。另一档
  /// `followings_comments`（仅我关注的人可评）行不行取决于我有没有关注作者，
  /// 光看枚举判断不了，因此一律按可评论处理、不做任何限制。
  bool get isCommentClosed => commentPermission == 'no_comments';

  factory Post.fromJson(Map<String, dynamic> j) {
    final mediaRaw = j['media'];
    final media = <MediaItem>[];
    if (mediaRaw is List) {
      for (final m in mediaRaw) {
        final mm = asMap(m);
        final url = asString(mm['url']);
        if (url.isNotEmpty) media.add(MediaItem.fromJson(mm));
      }
    }
    final collectionRaw = j['post_collection'];
    return Post(
      id: asString(j['id']),
      raw: j,
      isTimedPost: asBool(j['is_timed_post']),
      visibility: asString(j['visibility']),
      isPinned: asBool(j['is_pinned']),
      commentsCount: asInt(j['comments_count']),
      postType: asString(j['post_type']),
      commentPermission: asString(j['comment_permission']),
      createdAt: asDateTime(j['created_at']),
      postCollectionId: asString(j['post_collection_id']),
      isCollectionPinned: asBool(j['is_collection_pinned']),
      isThanked: asBool(j['is_thanked']),
      showType: asString(j['show_type']),
      content: asString(j['content']),
      media: media,
      user: j['user'] is Map
          ? SimpleUser.fromJson(asMap(j['user']))
          : SimpleUser.empty,
      isVoted: asBool(j['is_voted']),
      isFavourited: asBool(j['is_favourited']),
      isOwner: asBool(j['is_owner']),
      isShow: asBool(j['is_show'], true),
      isReviewing: asBool(j['is_reviewing']),
      postCollection:
          collectionRaw is Map ? PostCollection.fromJson(asMap(collectionRaw)) : null,
    );
  }
}

/// 评论对象。字段按官方 Web 端对评论的解析还原（见 main.dart.js 的
/// 评论模型）：id / created_at / replies_count / content / media / user /
/// is_voted / votes_count / is_owner / is_author / preview_replies /
/// replied_user / is_pinned。
///
/// 回复楼层有两个来源：
/// * 接口内嵌的 `preview_replies`（该条评论下的前几条回复）；
/// * 独立的回复列表端点 `GET api/v2/comments/replies?comment_id=`
///   （2026-09-16 实测存在，见《四需求可行性-探查报告.md》第三节，
///   修正了"没有单独回复列表端点"的旧结论）。
class Comment {
  Comment({
    required this.id,
    required this.content,
    required this.createdAt,
    required this.user,
    required this.parentId,
    required this.repliesCount,
    required this.repliedUser,
    required this.replies,
    required this.isVoted,
    required this.isOwner,
    required this.isAuthor,
    required this.isPinned,
    required this.media,
    required this.raw,
  });

  final String id;
  final String content;
  final DateTime? createdAt;
  final SimpleUser user;

  /// 父评论 id（回复某条评论时服务端返回）。
  final String parentId;

  /// 该条评论下的回复总数。
  final int repliesCount;

  /// 被回复的用户（「回复 @某人」时展示）。
  ///
  /// 注意：**回复他人评论**时 POST 的响应里该字段为 null（服务端未回填），
  /// 要展示"回复 @谁"需用本地已知的父评论作者。
  final SimpleUser? repliedUser;

  /// 接口内嵌的回复列表（preview_replies，通常只是前 3 条）。
  final List<Comment> replies;

  /// 点赞态。本地操作后会覆盖（乐观更新，见 actions.toggleCommentVote）。
  bool isVoted;

  /// 是否为当前登录用户本人发出的评论。
  final bool isOwner;

  /// 评论者是否为这条动态的作者本人（服务端给出的判定，与 UI 本地判定
  /// `_isAuthor` 互为补充：服务端没给时 UI 自己比对动态作者）。
  final bool isAuthor;

  final bool isPinned;

  /// 评论附带的媒体。**发表情就是走这里**：官方把评论里的表情作为
  /// media 图片项（`{type:"image", url}`）随评论一起发送。
  final List<MediaItem> media;

  final Map<String, dynamic> raw;

  /// 点赞数。
  ///
  /// **只有自己的评论（is_owner=true）服务端才下发该键**，他人评论无论
  /// 点赞与否整键都不返回（与赞数无关，见探查报告 3.3 的控制变量实验）。
  /// 因此他人评论拿不到点赞数，UI 只能渲染"已赞/未赞"状态。
  int? get votesCount {
    final v = raw['votes_count'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return null;
  }

  factory Comment.fromJson(Map<String, dynamic> j) {
    final repliesRaw = j['preview_replies'];
    final replies = <Comment>[];
    if (repliesRaw is List) {
      for (final r in repliesRaw) {
        if (r is Map) {
          final rc = Comment.fromJson(asMap(r));
          if (rc.id.isNotEmpty) replies.add(rc);
        }
      }
    }
    final replied = j['replied_user'];
    final mediaRaw = j['media'];
    final media = <MediaItem>[];
    if (mediaRaw is List) {
      for (final m in mediaRaw) {
        final mm = asMap(m);
        final url = asString(mm['url']);
        if (url.isNotEmpty) media.add(MediaItem.fromJson(mm));
      }
    }
    return Comment(
      id: asString(j['id']),
      content: asString(j['content']),
      createdAt: asDateTime(j['created_at']),
      user: j['user'] is Map
          ? SimpleUser.fromJson(asMap(j['user']))
          : SimpleUser.empty,
      parentId: asString(j['comment_id'], asString(j['parent_id'])),
      repliesCount: asInt(j['replies_count']),
      repliedUser:
          replied is Map ? SimpleUser.fromJson(asMap(replied)) : null,
      replies: replies,
      isVoted: asBool(j['is_voted']),
      isOwner: asBool(j['is_owner']),
      isAuthor: asBool(j['is_author']),
      isPinned: asBool(j['is_pinned']),
      media: media,
      raw: j,
    );
  }
}

/// 系统表情包（GET api/v2/emojis/packages → {id, name, icon}）。
class EmojiPackage {
  const EmojiPackage({
    required this.id,
    required this.name,
    required this.icon,
  });

  final String id;
  final String name;

  /// 包封面（静态资源直链）。
  final String icon;

  factory EmojiPackage.fromJson(Map<String, dynamic> j) => EmojiPackage(
        id: asString(j['id']),
        name: asString(j['name'], '表情包'),
        icon: asString(j['icon']),
      );
}

/// 单个表情（系统包内或"我的表情"，统一 {id, url}，url 为七牛直链）。
class Emoji {
  const Emoji({required this.id, required this.url});

  final String id;
  final String url;

  factory Emoji.fromJson(Map<String, dynamic> j) => Emoji(
        id: asString(j['id']),
        url: asString(j['url']),
      );

  /// 静态图缩略地址（七牛 imageView2），面板网格与待发条用小图省流。
  String get thumbUrl {
    if (!url.startsWith('http')) return url;
    return url.contains('?') ? '$url&imageView2/2/w/120' : '$url?imageView2/2/w/120';
  }
}

/// 他人主页头部（GET api/v2/users/{id}）。
///
/// 服务端只给"对外字段"（无手机号 / 积分 / 访客数），且关系态直接给出，
/// 主页无需再发请求判断"是否已关注"。
///
/// 隐私口径（探查报告 2.2 实测）：`is_hide_gender_age=true` 时响应里没有
/// `gender` / `age`，但 **`birthday` / `constellation` 仍然下发** ——
/// 属于服务端的隐私漏洞，本客户端不展示生日，避免把它显式呈现。
class UserProfile {
  const UserProfile({
    required this.user,
    required this.bio,
    required this.level,
    required this.badgesCount,
    required this.createdAt,
    required this.isFollowing,
    required this.isFollower,
    required this.isFriend,
    required this.isMuted,
    required this.isBlocked,
    required this.canPrivateMessage,
    this.raw = const <String, dynamic>{},
  });

  final SimpleUser user;
  final String bio;
  final int level;
  final int badgesCount;
  final DateTime? createdAt;

  /// 与当前登录用户的关系态。
  final bool isFollowing;
  final bool isFollower;
  final bool isFriend;
  final bool isMuted;
  final bool isBlocked;
  final bool canPrivateMessage;

  final Map<String, dynamic> raw;

  factory UserProfile.fromJson(Map<String, dynamic> j) => UserProfile(
        user: SimpleUser.fromJson(j),
        bio: asString(j['bio']),
        level: asInt(j['level']),
        badgesCount: asInt(j['badges_count']),
        createdAt: asDateTime(j['created_at']),
        isFollowing: asBool(j['is_following']),
        isFollower: asBool(j['is_follower']),
        isFriend: asBool(j['is_friend']),
        isMuted: asBool(j['is_muted']),
        isBlocked: asBool(j['is_blocked']),
        canPrivateMessage: asBool(j['can_private_message']),
        raw: j,
      );
}
