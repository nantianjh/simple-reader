import 'package:flutter/foundation.dart';

import '../api/api_exception.dart';
import '../api/models.dart';
import '../api/simple_api.dart';
import '../auth/jwt_utils.dart';
import '../auth/token_store.dart';
import '../util/app_log.dart';

/// 鉴权状态机。
enum AuthStatus {
  /// 启动后尚未读取本地存储。
  initializing,

  /// 本地没有 token。
  missing,

  /// 有 token，正在向服务端确认。
  verifying,

  /// token 可用。
  ready,

  /// token 存在但服务端拒绝（401/403）或本地已过期。
  invalid,
}

/// 全局鉴权与应用状态。
///
/// 账号密码登录方案按需求暂缓，本类只保留扩展位：
/// [loginWithToken] 是唯一的凭证入口，将来接入登录流程时
/// 只需在拿到 token 后调用同一方法即可，UI 与业务层无需改动。
class AppState extends ChangeNotifier {
  AppState({SimpleApi? api, TokenStore? store})
      : _api = api ?? SimpleApi(),
        _store = store ?? TokenStore.instance;

  final SimpleApi _api;
  final TokenStore _store;

  AuthStatus _status = AuthStatus.initializing;
  String? _token;
  JwtInfo? _jwt;
  SimpleUser? _currentUser;
  String? _errorMessage;
  DateTime? _tokenSavedAt;
  bool _fromCache = false;
  bool _webLoginWaiting = false;
  bool _webPeeking = false;

  AuthStatus get status => _status;
  String? get token => _token;
  JwtInfo? get jwt => _jwt;
  SimpleUser? get currentUser => _currentUser;
  String? get errorMessage => _errorMessage;
  DateTime? get tokenSavedAt => _tokenSavedAt;

  /// 应用内网页登录进行中（原生 WebView 已打开、等待凭证回传）。
  bool get webLoginWaiting => _webLoginWaiting;

  /// 置位/复位网页登录等待态。复位时无论成败，配置页的等待 UI 都会收起。
  void setWebLoginWaiting(bool v) {
    if (_webLoginWaiting == v) return;
    _webLoginWaiting = v;
    notifyListeners();
  }

  /// 正在离屏静默检测网页端登录态（不打开可见页面，凭证页自动接管用）。
  bool get webPeeking => _webPeeking;

  /// 置位/复位离屏检测态。检测结束（无论成败）都必须复位，避免 UI 卡在等待。
  void setWebPeeking(bool v) {
    if (_webPeeking == v) return;
    _webPeeking = v;
    notifyListeners();
  }

  /// 当前用户信息是否为本地缓存（未成功拉取时展示快照昵称）。
  bool get userIsCached => _fromCache;

  bool get hasToken => _token != null && _token!.isNotEmpty;
  bool get isReady => _status == AuthStatus.ready;
  /// 启动流程：读取本地 token → 本地校验 → 服务端校验。
  Future<void> bootstrap() async {
    _status = AuthStatus.initializing;
    notifyListeners();

    final saved = await _store.read();
    if (saved == null) {
      _status = AuthStatus.missing;
      log.i(LogTag.auth, '本地没有保存 token，进入配置页');
      notifyListeners();
      return;
    }

    _token = saved;
    _jwt = parseJwt(saved);
    _tokenSavedAt = await _store.savedAt();
    log.i(
      LogTag.auth,
      '读到他机凭证：长度 ${saved.length}，JWT 形态=${_jwt!.valid}，'
      'userId=${_jwt!.userId ?? '-'}，到期=${_formatDate(_jwt!.expiresAt)}',
    );

    // 本地就能判定过期时，不再发无意义的请求。
    if (!_jwt!.valid || _jwt!.isExpired) {
      _status = AuthStatus.invalid;
      _errorMessage = !_jwt!.valid
          ? (_jwt!.reason ?? 'token 格式不正确')
          : 'token 已于 ${_formatDate(_jwt!.expiresAt)} 过期';
      _fromCache = true;
      _currentUser = await _cachedUser();
      log.w(LogTag.auth, '凭证本地判定不可用：$_errorMessage');
      notifyListeners();
      return;
    }

    _status = AuthStatus.verifying;
    notifyListeners();
    await _verifyRemote(silent: true);
  }

  /// 用自定义 token 登录。
  ///
  /// 这是"自定义 token"方案的入口，也是将来"账号登录"方案的汇合点。
  Future<bool> loginWithToken(String rawToken) async {
    final token = rawToken.trim();
    final info = parseJwt(token);

    if (!info.valid) {
      // 结构不合法时不写入本地，直接报错。
      _status = hasToken ? _status : AuthStatus.missing;
      _errorMessage = info.reason ?? 'token 格式不正确';
      notifyListeners();
      return false;
    }

    if (info.isExpired) {
      _errorMessage = '该 token 已于 ${_formatDate(info.expiresAt)} 过期，请重新获取';
      notifyListeners();
      return false;
    }

    _token = token;
    _jwt = info;
    _errorMessage = null;
    _status = AuthStatus.verifying;
    notifyListeners();

    // 本地先落盘，保证即使网络不可用也不会丢掉用户填的 token。
    await _store.write(token);

    final ok = await _verifyRemote(silent: false);
    return ok;
  }

  /// 重新校验当前 token。
  Future<bool> revalidate() async {
    if (!hasToken) return false;
    _status = AuthStatus.verifying;
    notifyListeners();
    return _verifyRemote(silent: false);
  }

  Future<bool> _verifyRemote({required bool silent}) async {
    final token = _token;
    if (token == null) return false;
    try {
      final me = await _api.fetchCurrentUser(token: token);
      _currentUser = me;
      _fromCache = me == null;
      if (me != null) {
        await _store.write(token, nickname: me.nickname);
      }
      _status = AuthStatus.ready;
      _errorMessage = null;
      _tokenSavedAt = await _store.savedAt();
      log.i(LogTag.auth, '凭证校验通过：${me?.nickname ?? '（未取到昵称）'}');
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      if (e.requiresReauth) {
        _status = AuthStatus.invalid;
        _errorMessage = e.message;
        _fromCache = true;
        _currentUser = await _cachedUser();
        log.w(LogTag.auth, '凭证已被服务端拒绝：${e.message}');
        notifyListeners();
        return false;
      }
      // 网络类错误：token 本身可能没问题，保持可用但给出提示。
      if (silent) {
        _status = AuthStatus.ready;
        _errorMessage = '无法连接服务端（${e.message}），当前使用本地缓存状态';
        _currentUser = await _cachedUser();
        _fromCache = true;
      } else {
        _status = hasToken ? AuthStatus.invalid : AuthStatus.missing;
        _errorMessage = e.message;
      }
      log.w(LogTag.auth, '凭证校验失败（网络类）：${e.message}');
      notifyListeners();
      return false;
    } catch (e) {
      if (silent) {
        _status = AuthStatus.ready;
        _errorMessage = '校验 token 时出错：$e';
        _currentUser = await _cachedUser();
        _fromCache = true;
      } else {
        _status = AuthStatus.invalid;
        _errorMessage = '校验 token 时出错：$e';
      }
      log.e(LogTag.auth, '凭证校验异常：$e');
      notifyListeners();
      return false;
    }
  }

  Future<SimpleUser?> _cachedUser() async {
    final nick = await _store.cachedNickname();
    if (nick == null) return null;
    return SimpleUser(
      id: '',
      nickname: nick,
      gender: '',
      avatarUrl: '',
      avatarColor: '',
      isOfficial: false,
      isPrivacyEnabled: false,
      isNewUser: false,
    );
  }

  /// 退出登录：清除本地 token。
  Future<void> logout() async {
    await _store.clear();
    _token = null;
    _jwt = null;
    _currentUser = null;
    _status = AuthStatus.missing;
    _errorMessage = null;
    _tokenSavedAt = null;
    _fromCache = false;
    notifyListeners();
  }

  /// 业务层捕获到 401 时调用，把全局状态切到失效态。
  void markUnauthorized(String message) {
    _status = AuthStatus.invalid;
    _errorMessage = message;
    _fromCache = true;
    notifyListeners();
  }

  /// 清除一次性错误提示。
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  static String _formatDate(DateTime? d) {
    if (d == null) return '未知时间';
    final local = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
