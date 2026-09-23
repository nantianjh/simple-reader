/// 全局 API 常量。
///
/// 全部取值来自项目文档《搜索API契约_已还原.md》与《Simplexcel-API分析报告.html》，
/// 不做任何推测性修改。
class ApiConfig {
  ApiConfig._();

  /// 服务端根地址。
  static const String baseUrl = 'https://simple.imsummer.cn/';

  /// 有效版本前缀。契约第一节明确：搜索结果只在 v3 可用，v2 搜索会挂起。
  static const String apiV3 = 'api/v3/';

  /// 内容读写接口前缀（来自 Simplexcel 报告的远端路径常量）。
  static const String apiV2 = 'api/v2/';

  /// 媒体静态资源主机（七牛）。
  static const String mediaHost = 'https://static-simple.imsummer.cn';

  /// 七牛缩略图参数后缀，追加到源 URL 上。
  static const String thumbSuffix = '?imageView2/2/w/300';

  /// 浏览器 UA。
  ///
  /// 契约第六节明确要求自建客户端保持浏览器 UA；换成 `Dart/x.y (dart:io)`
  /// 之类的 UA 存在被区别对待的风险。此处必须显式覆盖 Dart 默认 UA。
  static const String browserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  /// 客户端指纹请求头，原样照抄浏览器真实请求。
  static Map<String, String> fingerprintHeaders() => const {
        'appVersionCode': '2',
        'appVersionName': '1.0.0',
        'channel': 'web',
        'countryCode': 'CN',
        'end': 'web',
        'languageCode': 'zh',
        'os': '3',
        'Referer': 'https://simple.imsummer.cn/web',
        'Accept': '*/*',
        'Accept-Language': 'zh',
        'User-Agent': browserUserAgent,
      };

  /// 串行限速：契约第六节要求单线程串行 + 每页间隔 >= 1s。
  static const Duration minRequestGap = Duration(milliseconds: 1200);

  /// 建立连接超时。
  static const Duration connectTimeout = Duration(seconds: 20);

  /// 接收响应超时。
  ///
  /// 必须显式设置：契约提到 v2 部分接口会"建立连接后 0 字节挂起"，
  /// 没有这个超时页面会无限转圈。
  static const Duration receiveTimeout = Duration(seconds: 30);

  /// 官方 Web 端固定传 10。
  static const int defaultPerPage = 10;

  // ---------------------------------------------------------- 官方分享链接

  /// 动态的官方分享链接，与官方 App"复制链接"生成的完全一致
  /// （产物 bEL()：`A.au() + "sharePost?id=" + postId`）。
  ///
  /// 该地址是一张"唤起 App"降落页（H5 不校验 id）：Android 唤起
  /// `simple://sharePost?id=`，iOS 走通用链接，失败 3 秒后回落下载页。
  /// 对方装了官方 App 就直接进动态，没装则落到官方下载页。
  ///
  /// **备忘录（2026-09-17 已落地）**：分享链接自 v1.8.0 起默认走应用内
  /// WebView（`actions.dart` 的 openLink，可在设置里切回系统浏览器），
  /// 链接本身不变。
  static String sharePostUrl(String postId) =>
      '${baseUrl}sharePost?id=$postId';

  /// 用户主页的官方分享链接（`shareFriend?id=<userId>`）。
  static String shareUserUrl(String userId) =>
      '${baseUrl}shareFriend?id=$userId';
}
