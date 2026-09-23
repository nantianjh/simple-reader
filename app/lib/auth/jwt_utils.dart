import 'dart:convert';

/// JWT 解析结果。
///
/// 契约第二节：token 是 HS256 的 JWT，payload 含 `user_id` 与 `exp`，
/// 有效期约 30 天，过期返回 401。
class JwtInfo {
  const JwtInfo({
    required this.valid,
    this.userId,
    this.expiresAt,
    this.issuedAt,
    this.reason,
  });

  /// 是否是一个结构合法的 JWT。
  final bool valid;

  final String? userId;
  final DateTime? expiresAt;
  final DateTime? issuedAt;

  /// 不合法时的原因描述。
  final String? reason;

  /// 本地判断是否已过期。
  bool get isExpired {
    final exp = expiresAt;
    if (exp == null) return false;
    return DateTime.now().isAfter(exp);
  }

  /// 剩余有效期。
  Duration? get remaining {
    final exp = expiresAt;
    if (exp == null) return null;
    return exp.difference(DateTime.now());
  }

  /// 是否临期（7 天内）。用于提前提醒用户换 token。
  bool get isExpiringSoon {
    final r = remaining;
    if (r == null) return false;
    return r.inDays <= 7;
  }
}

/// 解析 JWT。仅做本地结构解析，不校验签名（签名由服务端校验）。
JwtInfo parseJwt(String token) {
  final trimmed = token.trim();
  if (trimmed.isEmpty) {
    return const JwtInfo(valid: false, reason: 'token 为空');
  }

  // 容错：用户从浏览器复制时可能带上 "Bearer " 前缀。
  final normalized =
      trimmed.toLowerCase().startsWith('bearer ') ? trimmed.substring(7).trim() : trimmed;

  final parts = normalized.split('.');
  if (parts.length != 3) {
    return const JwtInfo(
      valid: false,
      reason: '格式不正确：JWT 应为三段，以「.」分隔',
    );
  }

  try {
    final payload = _decodeSegment(parts[1]);
    if (payload == null) {
      return const JwtInfo(valid: false, reason: '无法解析 payload 段');
    }
    final expRaw = payload['exp'];
    final iatRaw = payload['iat'];
    return JwtInfo(
      valid: true,
      userId: payload['user_id']?.toString(),
      expiresAt: expRaw is num
          ? DateTime.fromMillisecondsSinceEpoch(expRaw.toInt() * 1000)
          : null,
      issuedAt: iatRaw is num
          ? DateTime.fromMillisecondsSinceEpoch(iatRaw.toInt() * 1000)
          : null,
    );
  } catch (_) {
    return const JwtInfo(valid: false, reason: 'payload 不是合法 JSON');
  }
}

Map<String, dynamic>? _decodeSegment(String segment) {
  // base64Url 解码需要补齐 padding。
  var s = segment.replaceAll('-', '+').replaceAll('_', '/');
  final pad = s.length % 4;
  if (pad == 2) {
    s += '==';
  } else if (pad == 3) {
    s += '=';
  } else if (pad == 1) {
    return null;
  }
  final bytes = base64.decode(s);
  final text = utf8.decode(bytes);
  final decoded = jsonDecode(text);
  if (decoded is Map) {
    return decoded.map((k, v) => MapEntry(k.toString(), v));
  }
  return null;
}
