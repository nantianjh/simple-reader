import 'package:flutter/material.dart';

import '../api/api_config.dart';
import '../api/api_exception.dart';
import '../api/models.dart';
import '../api/simple_api.dart';
import '../data/settings.dart';
import '../data/vote_overlay.dart';
import '../platform/native_bridge.dart';
import '../state/app_scope.dart';
import '../util/app_log.dart';
import 'theme.dart';
import 'token_setup_page.dart';

/// 内容互动的公共实现。
///
/// 点赞 / 收藏 / 评论都是"先乐观更新、失败回滚"的模式，
/// 抽到这里避免在多个页面重复。

/// 点赞 / 取消点赞。
///
/// [post] 的 [Post.isVoted] 会被就地更新，返回是否操作成功。
Future<bool> toggleVote(BuildContext context, Post post) async {
  final app = AppScope.read(context);
  final token = app.token;
  if (token == null || token.isEmpty) return false;

  final target = !post.isVoted;
  final previous = post.isVoted;
  post.isVoted = target; // 乐观更新

  try {
    await SimpleApi().vote(postId: post.id, on: target, token: token);
    // 记入本地点赞覆盖层：内容缓存里的 is_voted 还是旧值，
    // 缓存续读解析时要靠这层把点赞态补回来。
    await VoteOverlay.instance.recordPost(post.id, voted: target);
    log.i(LogTag.ui, '${target ? '点赞' : '取消点赞'}成功：${post.id}');
    return true;
  } on ApiException catch (e) {
    post.isVoted = previous; // 回滚
    log.w(LogTag.ui, '${target ? '点赞' : '取消点赞'}失败：${post.id}｜${e.message}');
    if (!context.mounted) return false;
    if (e.requiresReauth) {
      app.markUnauthorized(e.message);
    } else {
      _toast(context, e.message);
    }
    return false;
  } catch (e, st) {
    post.isVoted = previous;
    log.exception(LogTag.ui, '点赞异常：${post.id}', e, st);
    if (context.mounted) _toast(context, '操作失败：$e');
    return false;
  }
}

/// 收藏 / 取消收藏。
///
/// [post] 的 [Post.isFavourited] 会被就地更新（乐观更新、失败回滚），
/// 返回是否操作成功。
Future<bool> toggleFavourite(BuildContext context, Post post) async {
  final app = AppScope.read(context);
  final token = app.token;
  if (token == null || token.isEmpty) return false;

  final target = !post.isFavourited;
  final previous = post.isFavourited;
  post.isFavourited = target; // 乐观更新

  try {
    await SimpleApi().favourite(postId: post.id, on: target, token: token);
    log.i(LogTag.ui, '${target ? '收藏' : '取消收藏'}成功：${post.id}');
    if (context.mounted) _toast(context, target ? '已加入收藏' : '已取消收藏');
    return true;
  } on ApiException catch (e) {
    post.isFavourited = previous; // 回滚
    log.w(LogTag.ui, '${target ? '收藏' : '取消收藏'}失败：${post.id}｜${e.message}');
    if (!context.mounted) return false;
    if (e.requiresReauth) {
      app.markUnauthorized(e.message);
    } else {
      _toast(context, e.message);
    }
    return false;
  } catch (e, st) {
    post.isFavourited = previous;
    log.exception(LogTag.ui, '收藏异常：${post.id}', e, st);
    if (context.mounted) _toast(context, '操作失败：$e');
    return false;
  }
}

/// 取消收藏（收藏列表内使用）。
Future<bool> removeFavourite(BuildContext context, String postId) async {
  final app = AppScope.read(context);
  final token = app.token;
  if (token == null || token.isEmpty) return false;
  try {
    await SimpleApi().favourite(postId: postId, on: false, token: token);
    log.i(LogTag.ui, '取消收藏成功：$postId');
    if (context.mounted) _toast(context, '已取消收藏');
    return true;
  } on ApiException catch (e) {
    log.w(LogTag.ui, '取消收藏失败：$postId｜${e.message}');
    if (!context.mounted) return false;
    if (e.requiresReauth) {
      app.markUnauthorized(e.message);
    } else {
      _toast(context, e.message);
    }
    return false;
  }
}

/// 评论点赞 / 取消。乐观更新、失败回滚（与动态点赞同一模式）。
///
/// [comment.isVoted] 会被就地更新，返回是否操作成功。
/// 主楼与回复楼层都是评论，同一端点（api/v2/comment_votes）通用。
Future<bool> toggleCommentVote(BuildContext context, Comment comment) async {
  final app = AppScope.read(context);
  final token = app.token;
  if (token == null || token.isEmpty) return false;

  final target = !comment.isVoted;
  final previous = comment.isVoted;
  comment.isVoted = target; // 乐观更新

  try {
    await SimpleApi()
        .commentVote(commentId: comment.id, on: target, token: token);
    // 同动态点赞：评论缓存里 is_voted 也是旧值，靠覆盖层补。
    await VoteOverlay.instance.recordComment(comment.id, voted: target);
    log.i(LogTag.ui, '${target ? '点赞' : '取消点赞'}评论成功：${comment.id}');
    return true;
  } on ApiException catch (e) {
    comment.isVoted = previous; // 回滚
    log.w(LogTag.ui,
        '${target ? '点赞' : '取消点赞'}评论失败：${comment.id}｜${e.message}');
    if (!context.mounted) return false;
    if (e.requiresReauth) {
      app.markUnauthorized(e.message);
    } else {
      _toast(context, e.message);
    }
    return false;
  } catch (e, st) {
    comment.isVoted = previous;
    log.exception(LogTag.ui, '评论点赞异常：${comment.id}', e, st);
    if (context.mounted) _toast(context, '操作失败：$e');
    return false;
  }
}

/// 统一的链接打开入口：默认走应用内 WebView 的「链接模式」，关闭开关时
/// 回退系统浏览器。
///
/// 链接模式对非 http(s) 导航的处理与真实浏览器同口径：页面里的
/// `simple://` 等自定义协议转交系统唤起对应应用，唤起成功后容器收掉。
/// 官方分享页因此可以在内置容器里一键跳进官方 App 的对应页面；
/// 没有应用能接时留在页面里，走官方自己的回落（下载页）。
///
/// [context] 可为 null（无上下文的场景不做失败提示）。
/// 返回是否成功打开。
Future<bool> openLink(BuildContext? context, String url) async {
  if (url.isEmpty) return false;
  if (AppSettings.instance.openLinksInApp) {
    final ok = await NativeBridge.instance
        .openLinkInApp(url, title: _linkTitle(url));
    if (ok) return true;
    // 应用内容器拉起失败（极端情况）才落到下面的系统浏览器。
  }
  final ok = await NativeBridge.instance.openUrl(url);
  log.d(LogTag.ui, '打开链接：$url → 应用内成功=${AppSettings.instance.openLinksInApp}，最终=$ok');
  if (!ok && context != null && context.mounted) {
    _toast(context, '没有可用的浏览器应用');
  }
  return ok;
}

/// 应用内容器顶栏标题：官方分享页给「在 Simple 中打开」，其余给中性标题。
String _linkTitle(String url) =>
    url.startsWith('${ApiConfig.baseUrl}sharePost')
        ? '在 Simple 中打开'
        : '外部链接';

/// 用浏览器打开官方分享页（"在 Simple 中打开"）。
///
/// 分享链接（[ApiConfig.sharePostUrl]）是一张"唤起 App"降落页：页面会
/// 尝试 `simple://sharePost?id=` 深链。自 v1.8.3 起，内置浏览器（链接
/// 模式）把这类导航转交系统——装了官方 App 就直接跳进对应动态，
/// 没装则留在页面里走官方自己的回落（官方下载页）。链接本身不变，
/// 设置里可切回系统浏览器打开。
Future<void> openInSimple(BuildContext context, String url) async {
  if (url.isEmpty) return;
  await openLink(context, url);
}

/// 统一的 token 缺失 / 失效提示。
void toastAuthIssue(BuildContext context, String message) {
  _toast(context, message);
}

void _toast(BuildContext context, String msg) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2, milliseconds: 400),
      ),
    );
}

/// 提示条：token 失效时置顶展示，并提供直达配置页的入口。
class AuthBanner extends StatelessWidget {
  const AuthBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 9, 8, 9),
      color: AppTheme.dangerBackground,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.lock_outline_rounded,
              size: 15, color: AppTheme.danger),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12.5,
                color: AppTheme.danger,
                height: 1.5,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const TokenSetupPage()),
            ),
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.danger,
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('去配置', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}
