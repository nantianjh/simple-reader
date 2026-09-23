import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../util/app_log.dart';
import 'api_config.dart';
import 'api_exception.dart';
import 'models.dart';

/// 底层 HTTP 客户端。
///
/// 直接用 `dart:io` 的 [HttpClient]，不依赖 dio。职责：
/// 1. 注入浏览器指纹请求头与 `Authorization`（裸 JWT，无 `Bearer` 前缀）；
/// 2. 串行限速（契约第六节：单线程 + 每页间隔 >= 1s）；
/// 3. 把底层异常归一化为 [ApiException]；
/// 4. 把响应体解析成"元素为 Map 的列表"，同时容忍裸数组与包裹结构。
class ApiClient {
  ApiClient._();

  static final ApiClient instance = ApiClient._();

  HttpClient? _http;

  /// 上一次请求发起时间，用于限速。
  DateTime? _lastRequestAt;

  /// 把请求串成队列，避免同时打多个请求触发风控。
  Future<void> _queue = Future<void>.value();

  HttpClient get _client {
    var c = _http;
    if (c == null) {
      c = HttpClient();
      c.connectionTimeout = ApiConfig.connectTimeout;
      c.idleTimeout = const Duration(seconds: 15);
      // 显式指定浏览器 UA。dart:io 默认会发 "Dart/x.y (dart:io)"，
      // 契约第六节要求必须保持浏览器 UA，否则有被区别对待的风险。
      c.userAgent = ApiConfig.browserUserAgent;
      // 尊重 http_proxy / https_proxy 环境变量。
      c.findProxy = HttpClient.findProxyFromEnvironment;
      _http = c;
    }
    return c;
  }

  /// 限速 + 排队，保证串行。
  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      final now = DateTime.now();
      if (_lastRequestAt != null) {
        final wait = ApiConfig.minRequestGap - now.difference(_lastRequestAt!);
        if (wait > Duration.zero) {
          await Future<void>.delayed(wait);
        }
      }
      _lastRequestAt = DateTime.now();
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    }).catchError((_) {
      // 保证队列不会因为某次失败而中断。
    });
    return completer.future;
  }

  /// GET + 查询串。
  Future<dynamic> getJson(
    String path, {
    required String token,
    Map<String, dynamic>? query,
  }) {
    return _request('GET', path, token: token, query: query);
  }

  /// POST / DELETE，body 为 JSON。
  Future<dynamic> sendJson(
    String method,
    String path, {
    required String token,
    Map<String, dynamic>? body,
    Map<String, dynamic>? query,
  }) {
    return _request(method, path, token: token, query: query, body: body);
  }

  Future<dynamic> _request(
    String method,
    String path, {
    required String token,
    Map<String, dynamic>? query,
    Map<String, dynamic>? body,
  }) {
    return _serialized(() async {
      final uri = _buildUri(path, query);
      final sw = Stopwatch()..start();
      log.d(LogTag.net, '→ $method ${_short(uri)}'
          '${body == null ? '' : ' body=${jsonEncode(body)}'}');
      try {
        final req =
            await _client.openUrl(method, uri).timeout(ApiConfig.connectTimeout);

        ApiConfig.fingerprintHeaders().forEach(req.headers.set);
        // 契约第一节：裸 token，无 Bearer 前缀。
        req.headers.set('Authorization', token);

        if (body != null && method != 'GET') {
          final bytes = utf8.encode(jsonEncode(body));
          req.headers.contentType = ContentType.json;
          req.headers.contentLength = bytes.length;
          req.add(bytes);
        }

        final res = await req.close().timeout(ApiConfig.receiveTimeout);
        final text = await res
            .transform(utf8.decoder)
            .join()
            .timeout(ApiConfig.receiveTimeout);
        final decoded = _decode(res.statusCode, text, uri.toString());
        log.i(
          LogTag.net,
          '← ${res.statusCode} ${_short(uri)} '
          '${text.length} B ${AppLog.ms(sw)}',
        );
        return decoded;
      } on ApiException catch (e) {
        // 失败时把响应体片段记下来：接口行为异常（被静默忽略的参数、
        // 通用 404 等）只能靠原始响应判断。
        log.e(
          LogTag.net,
          '← 失败 ${e.statusCode ?? '-'} ${_short(uri)} ${AppLog.ms(sw)}｜${e.message}',
        );
        rethrow;
      } on TimeoutException {
        log.e(LogTag.net, '← 超时 ${_short(uri)} ${AppLog.ms(sw)}');
        throw ApiException(
          ApiErrorKind.timeout,
          '请求超时。服务端对异常请求可能表现为无响应，请确认 token 与网络后重试。',
          uri: uri.toString(),
        );
      } on SocketException catch (e) {
        log.e(LogTag.net, '← 网络错误 ${_short(uri)}｜${e.message}');
        throw ApiException(
          ApiErrorKind.network,
          '网络连接失败：${e.message}',
          uri: uri.toString(),
        );
      } on HandshakeException {
        log.e(LogTag.net, '← TLS 握手失败 ${_short(uri)}');
        throw ApiException(
          ApiErrorKind.network,
          'TLS 握手失败，请检查网络环境。',
          uri: uri.toString(),
        );
      } on HttpException catch (e) {
        log.e(LogTag.net, '← HTTP 协议错误 ${_short(uri)}｜${e.message}');
        throw ApiException(
          ApiErrorKind.network,
          'HTTP 协议错误：${e.message}',
          uri: uri.toString(),
        );
      } catch (e, st) {
        log.exception(LogTag.net, '← 请求异常 ${_short(uri)}', e, st);
        throw ApiException(
          ApiErrorKind.unknown,
          '请求失败：$e',
          uri: uri.toString(),
        );
      }
    });
  }

  /// 日志里用的短地址（省掉 scheme/host，保留路径与查询串）。
  String _short(Uri uri) {
    final q = uri.query.isEmpty ? '' : '?${uri.query}';
    return '${uri.path}$q';
  }

  Uri _buildUri(String path, Map<String, dynamic>? query) {
    final resolved = Uri.parse(ApiConfig.baseUrl).resolve(path);
    if (query == null || query.isEmpty) return resolved;
    return resolved.replace(
      queryParameters: query.map((k, v) => MapEntry(k, v?.toString() ?? '')),
    );
  }

  dynamic _decode(int code, String text, String uri) {
    // 非 2xx 时把响应体片段记进日志：排查"参数被静默忽略""通用 404"这类
    // 服务端行为时，原始响应是唯一证据。
    if (code < 200 || code >= 300) {
      log.w(LogTag.net, '响应体片段（$code）：${_snippet(text)}');
    }
    if (code == 401) {
      throw ApiException(
        ApiErrorKind.unauthorized,
        '登录已失效（401）。请在网页版重新登录后，把新的 token 填回来。',
        statusCode: code,
        uri: uri,
      );
    }
    if (code == 403) {
      throw ApiException(
        ApiErrorKind.forbidden,
        '无权访问（403）。该内容可能已被删除或对你不可见。',
        statusCode: code,
        uri: uri,
      );
    }
    if (code == 404) {
      throw ApiException(
        ApiErrorKind.notFound,
        '接口不存在（404）。',
        statusCode: code,
        uri: uri,
      );
    }
    if (code == 429) {
      throw ApiException(
        ApiErrorKind.rateLimited,
        '请求过于频繁（429）。请稍后再试，并保持低频率使用。',
        statusCode: code,
        uri: uri,
      );
    }
    if (code >= 500) {
      throw ApiException(
        ApiErrorKind.server,
        '服务端错误（$code）。',
        statusCode: code,
        uri: uri,
      );
    }
    if (code < 200 || code >= 300) {
      throw ApiException(
        ApiErrorKind.unknown,
        '请求失败（$code）。',
        statusCode: code,
        uri: uri,
      );
    }

    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    try {
      return jsonDecode(trimmed);
    } catch (_) {
      log.w(LogTag.net, '响应不是合法 JSON：${_snippet(text)}');
      throw ApiException(
        ApiErrorKind.decode,
        '响应不是合法 JSON。',
        statusCode: code,
        uri: uri,
      );
    }
  }

  /// 日志用的响应体片段（单行、限长）。
  static String _snippet(String text, [int max = 240]) {
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= max ? one : '${one.substring(0, max)}…';
  }

  /// 校验 token 是否可用。契约第六节建议只用读接口探测，不碰登录接口。
  Future<bool> ping({required String token}) async {
    try {
      final uri =
          Uri.parse(ApiConfig.baseUrl).resolve('${ApiConfig.apiV2}current_user');
      final req = await _client.getUrl(uri).timeout(ApiConfig.connectTimeout);
      ApiConfig.fingerprintHeaders().forEach(req.headers.set);
      req.headers.set('Authorization', token);
      final res = await req.close().timeout(ApiConfig.receiveTimeout);
      // 必须消费掉响应体，否则连接无法复用。
      await res.drain<void>().timeout(ApiConfig.receiveTimeout);
      final code = res.statusCode;
      return code >= 200 && code < 300;
    } catch (_) {
      return false;
    }
  }

  /// 释放底层连接池。
  void close() {
    _http?.close(force: true);
    _http = null;
  }
}

/// 把任意形态的响应体抽取成 `List<Map>`。
///
/// v3 契约是裸 JSON 数组；v2 系列文档未给出包裹结构，故同时容忍
/// `{data: [...]}` / `{list: [...]}` / `{items: [...]}` / `{data: {list: [...]}}`
/// 等常见包裹，避免因外壳差异导致整页空白。
List<Map<String, dynamic>> extractMapList(dynamic decoded) {
  final out = <Map<String, dynamic>>[];

  void walk(dynamic node, int depth) {
    if (depth > 4 || node == null) return;
    if (node is List) {
      for (final item in node) {
        if (item is Map) out.add(asMap(item));
      }
      return;
    }
    if (node is Map) {
      final m = asMap(node);
      for (final key in const [
        'data',
        'list',
        'items',
        'results',
        'records',
        'posts',
        'rows',
        'content',
        'channels',
        'tags',
        'comments',
        'favourites',
        'collections',
        'post_collections',
      ]) {
        final v = m[key];
        if (v is List) {
          walk(v, depth + 1);
          return;
        }
        if (v is Map) {
          walk(v, depth + 1);
          return;
        }
      }
    }
  }

  walk(decoded, 0);
  return out;
}

/// 从响应里抽取单个对象（用于 current_user 这类接口）。
Map<String, dynamic>? extractMap(dynamic decoded) {
  if (decoded is Map) {
    final m = asMap(decoded);
    for (final key in const ['data', 'user', 'current_user', 'result', 'item']) {
      final v = m[key];
      if (v is Map) return asMap(v);
    }
    return m;
  }
  if (decoded is List) {
    for (final item in decoded) {
      if (item is Map) return asMap(item);
    }
  }
  return null;
}
