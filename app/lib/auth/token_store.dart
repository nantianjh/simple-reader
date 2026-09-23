import 'package:flutter/services.dart';

/// Token 本地持久化。
///
/// 走自建的平台通道，落到 Android 原生的 `SharedPreferences`
/// （文件位于 `/data/data/<pkg>/shared_prefs/`，未 root 的设备上
/// 其它应用无法读取）。因此本工程不需要 shared_preferences 之类的插件，
/// 运行时零第三方依赖。
///
/// 每个方法都对平台异常做了吞并处理：凭证存储失败不应该让应用崩溃，
/// 最坏情况退化为"本次会话有效、下次要重新粘贴"。
class TokenStore {
  TokenStore._();

  static final TokenStore instance = TokenStore._();

  static const MethodChannel _channel =
      MethodChannel('cn.imsummer.simple_reader/store');

  static const String _keyToken = 'simple_auth_token';
  static const String _keySavedAt = 'simple_auth_token_saved_at';
  static const String _keyNickname = 'simple_auth_nickname';

  Future<String?> _get(String key) async {
    try {
      return await _channel.invokeMethod<String>('get', {'key': key});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> _set(String key, String value) async {
    try {
      await _channel.invokeMethod<void>('set', {'key': key, 'value': value});
    } on PlatformException {
      // 忽略：持久化失败不影响本次会话可用性。
    } on MissingPluginException {
      // 忽略。
    }
  }

  Future<void> _remove(String key) async {
    try {
      await _channel.invokeMethod<void>('remove', {'key': key});
    } on PlatformException {
      // 忽略。
    } on MissingPluginException {
      // 忽略。
    }
  }

  /// 读取已保存的 token。
  Future<String?> read() async {
    final v = await _get(_keyToken);
    if (v == null || v.trim().isEmpty) return null;
    return v.trim();
  }

  /// 保存 token，并记录写入时间与（可选的）昵称快照。
  Future<void> write(String token, {String? nickname}) async {
    await _set(_keyToken, token.trim());
    await _set(_keySavedAt, DateTime.now().toIso8601String());
    if (nickname != null && nickname.isNotEmpty) {
      await _set(_keyNickname, nickname);
    }
  }

  /// 最近一次写入时间。
  Future<DateTime?> savedAt() async {
    final v = await _get(_keySavedAt);
    if (v == null) return null;
    return DateTime.tryParse(v);
  }

  /// 昵称快照，避免每次启动都要请求一次用户信息。
  Future<String?> cachedNickname() => _get(_keyNickname);

  Future<void> clear() async {
    await _remove(_keyToken);
    await _remove(_keySavedAt);
    await _remove(_keyNickname);
  }

  /// 是否已配置 token。
  Future<bool> hasToken() async => (await read()) != null;
}
