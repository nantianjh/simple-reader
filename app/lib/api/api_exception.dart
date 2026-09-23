/// 错误分类，驱动 UI 给出可操作的提示。
enum ApiErrorKind {
  /// 网络不可达 / DNS / 连接被拒。
  network,

  /// 超时。契约提到 v2 异常请求的表现是"建立连接后 0 字节挂起"。
  timeout,

  /// 401：token 过期或无效，需重新取 token。
  unauthorized,

  /// 403：无权访问。
  forbidden,

  /// 404：资源不存在。
  notFound,

  /// 429：频率限制。契约要求不要并发、不要全量抓取。
  rateLimited,

  /// 5xx 服务端错误。
  server,

  /// 响应体不是预期结构，无法解析。
  decode,

  /// 其他未归类错误。
  unknown,
}

class ApiException implements Exception {
  ApiException(this.kind, this.message, {this.statusCode, this.uri});

  final ApiErrorKind kind;
  final String message;
  final int? statusCode;
  final String? uri;

  /// 是否属于"需要用户重新提供 token"的情形。
  bool get requiresReauth =>
      kind == ApiErrorKind.unauthorized || kind == ApiErrorKind.forbidden;

  @override
  String toString() => 'ApiException(${kind.name}$statusCode, $message)';
}
