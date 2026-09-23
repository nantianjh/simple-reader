import 'package:flutter/services.dart';

/// 缓存/存储用量统计。
class StorageStats {
  const StorageStats({required this.count, required this.bytes});

  static const StorageStats empty = StorageStats(count: 0, bytes: 0);

  final int count;
  final int bytes;

  String get readable {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }
}

/// 原生能力桥。
///
/// 工程约定零第三方运行时依赖，所有系统能力都经自建 [MethodChannel]
/// 落到 Android 原生实现（见 `MainActivity.kt`）：
///
/// * `store`   —— 键值对，落 SharedPreferences；
/// * `files`   —— 内容缓存文件，落应用私有目录 `files/content_cache`；
/// * `logs`    —— 运行日志文件，落应用私有目录 `files/logs`（与内容缓存分开放，
///                避免「清空内容缓存」把日志一起删掉）；
/// * `system`  —— 系统动作，目前只有「用默认浏览器打开链接」；
/// * `browser` —— 应用内浏览器容器（系统 WebView，见 `BrowserActivity.kt`）：
///                三种模式——网页版（open）、链接（openLink，深链可唤起
///                对应应用）、应用内登录（login）；原生拿到凭证或
///                「切换到阅读模式」时通过同一通道反向回调。
///
/// 所有方法都对平台异常做吞并处理——存储与系统动作失败不应该让应用崩溃，
/// 最坏情况退化为「本次会话不生效」。
class NativeBridge {
  NativeBridge._();

  static final NativeBridge instance = NativeBridge._();

  static const MethodChannel _store =
      MethodChannel('cn.imsummer.simple_reader/store');
  static const MethodChannel _files =
      MethodChannel('cn.imsummer.simple_reader/files');
  static const MethodChannel _logs =
      MethodChannel('cn.imsummer.simple_reader/logs');
  static const MethodChannel _system =
      MethodChannel('cn.imsummer.simple_reader/system');
  static const MethodChannel _browser =
      MethodChannel('cn.imsummer.simple_reader/browser');

  // ---------------------------------------------------------------- 键值对

  Future<String?> kvGet(String key) async {
    try {
      return await _store.invokeMethod<String>('get', {'key': key});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> kvSet(String key, String value) async {
    try {
      await _store.invokeMethod<void>('set', {'key': key, 'value': value});
    } on PlatformException {
      // 忽略：持久化失败不影响本次会话可用性。
    } on MissingPluginException {
      // 忽略。
    }
  }

  Future<void> kvRemove(String key) async {
    try {
      await _store.invokeMethod<void>('remove', {'key': key});
    } on PlatformException {
      // 忽略。
    } on MissingPluginException {
      // 忽略。
    }
  }

  // ---------------------------------------------------------------- 缓存文件

  Future<String?> fileRead(String name) async {
    try {
      return await _files.invokeMethod<String>('read', {'name': name});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> fileWrite(String name, String content) async {
    try {
      final ok = await _files
          .invokeMethod<bool>('write', {'name': name, 'content': content});
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> fileDelete(String name) async {
    try {
      await _files.invokeMethod<void>('delete', {'name': name});
    } on PlatformException {
      // 忽略。
    } on MissingPluginException {
      // 忽略。
    }
  }

  Future<List<String>> fileList() async {
    try {
      final list = await _files.invokeMethod<List<dynamic>>('list');
      if (list == null) return const [];
      return list.map((e) => e.toString()).toList();
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  Future<StorageStats> fileStats() async {
    try {
      final map = await _files.invokeMethod<Map<dynamic, dynamic>>('stats');
      if (map == null) return StorageStats.empty;
      final count = map['count'];
      final bytes = map['bytes'];
      return StorageStats(
        count: count is num ? count.toInt() : 0,
        bytes: bytes is num ? bytes.toInt() : 0,
      );
    } on PlatformException {
      return StorageStats.empty;
    } on MissingPluginException {
      return StorageStats.empty;
    }
  }

  /// 删除超过 [maxAgeDays] 天未修改的缓存文件。传 0 或负数表示不清理。
  Future<int> filePurge(int maxAgeDays) async {
    try {
      final n = await _files
          .invokeMethod<int>('purge', {'maxAgeDays': maxAgeDays});
      return n ?? 0;
    } on PlatformException {
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }

  /// 清空全部缓存文件。
  Future<int> fileClear() async {
    try {
      final n = await _files.invokeMethod<int>('clear');
      return n ?? 0;
    } on PlatformException {
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }

  // ---------------------------------------------------------------- 运行日志

  /// 追加写运行日志。原生侧会在文件超过上限时自动裁掉最旧的部分。
  Future<bool> logAppend(String text) async {
    if (text.isEmpty) return false;
    try {
      final ok = await _logs.invokeMethod<bool>('append', {'text': text});
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 读取日志文件全文（原生侧已按上限裁剪）。
  Future<String?> logRead() async {
    try {
      return await _logs.invokeMethod<String>('read');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> logClear() async {
    try {
      await _logs.invokeMethod<void>('clear');
    } on PlatformException {
      // 忽略。
    } on MissingPluginException {
      // 忽略。
    }
  }

  Future<int> logSize() async {
    try {
      final n = await _logs.invokeMethod<int>('size');
      return n ?? 0;
    } on PlatformException {
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }

  // ---------------------------------------------------------------- 系统动作

  /// 用系统默认浏览器打开 [url]。返回是否成功唤起（false 表示没有可用应用）。
  Future<bool> openUrl(String url) async {
    if (url.isEmpty) return false;
    try {
      final ok = await _system.invokeMethod<bool>('openUrl', {'url': url});
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  // ---------------------------------------------------------------- 数据备份

  /// 把备份文本写成一个文件。
  ///
  /// 落点是**用户可见的公共目录**：Android 10+ 走 MediaStore 写
  /// `Download/Simple阅读/`（不需要存储权限，系统「文件」与第三方文件管理器
  /// 立即可见，数据线也能直接拷走）；更早版本原生回落到应用外部私有目录
  /// `Android/data/<包名>/files/backups/`（无需权限，文件管理器与 adb 可取），
  /// 此时返回的是真实绝对路径。
  ///
  /// 返回**给用户看的位置描述**（如「下载/Simple阅读/xx.json」或回落时的绝对
  /// 路径），可直接展示；失败抛 [Exception]（message 可展示），
  /// 运行在没有原生实现的场合（桌面/测试）返回 null。
  Future<String?> exportBackup(String fileName, String content) async {
    try {
      return await _system.invokeMethod<String>(
        'exportBackup',
        {'fileName': fileName, 'content': content},
      );
    } on PlatformException catch (e) {
      // 把原生侧的具体原因（系统拒绝写入等）带给调用方，便于在 toast 里说清。
      throw Exception(e.message ?? '原生导出失败');
    } on MissingPluginException {
      return null;
    }
  }

  /// 让用户挑一个文件并读回文本（系统文件选择器，不需要存储权限）。
  /// 用户取消、读取失败时返回 null。
  Future<BackupFile?> importBackup() async {
    try {
      final map =
          await _system.invokeMethod<Map<dynamic, dynamic>>('importBackup');
      if (map == null) return null;
      return BackupFile(
        name: map['name']?.toString() ?? '',
        content: map['content']?.toString() ?? '',
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 把图片字节写入系统相册（v1.9.2 新增，配合「保存图片」功能）。
  ///
  /// Android 10+ 经 MediaStore 插入 `Pictures/Simple阅读`（无需任何存储
  /// 权限，相册立即可见，重名由系统自动去重）；更早版本没有免权限的公共
  /// 目录写法，原生回落到应用外部私有目录 `Android/data/<包名>/files/
  /// Pictures/Simple阅读/`（文件管理器可取，但相册不索引）。
  ///
  /// 返回给用户看的位置描述（如「相册/Simple阅读/xx.jpg」或完整路径）；
  /// 失败抛 [Exception]，message 可直接展示。
  Future<String> saveImageToGallery(
    Uint8List bytes,
    String fileName,
    String mime,
  ) async {
    try {
      final location = await _system.invokeMethod<String>('saveImage', {
        'bytes': bytes,
        'fileName': fileName,
        'mime': mime,
      });
      if (location == null || location.isEmpty) {
        throw Exception('原生侧未返回保存位置');
      }
      return location;
    } on PlatformException catch (e) {
      throw Exception(e.message ?? '保存失败');
    } on MissingPluginException {
      throw Exception('当前安装的版本不支持保存图片，请升级后重试');
    }
  }

  // ------------------------------------------------------ 应用内浏览器

  /// 在应用内 WebView 打开 [url]（官方网页版容器）。
  ///
  /// 页面加载完成时会静默读取一次网页端的登录信息：若用户在网页里
  /// 登录过，凭证会经 [setBrowserHandlers] 的 onAuthToken 自动同步。
  Future<bool> openInApp(String url) async {
    if (url.isEmpty) return false;
    try {
      final ok = await _browser.invokeMethod<bool>('open', {'url': url});
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 在应用内 WebView 打开一个链接（链接模式）。
  ///
  /// 与 [openInApp]（官方网页版）的区别在非 http(s) 导航的处理：
  /// 网页版刻意忽略（避免被页面带跳出去），链接模式转交系统
  /// （ACTION_VIEW）——页面里的 `simple://` 等深链会唤起对应应用，
  /// 唤起成功后容器自动收掉，等效真实浏览器访问链接的行为。
  ///
  /// [title] 为容器顶栏标题；空串时原生侧给中性标题。
  Future<bool> openLinkInApp(String url, {String? title}) async {
    if (url.isEmpty) return false;
    try {
      final ok = await _browser.invokeMethod<bool>('openLink', {
        'url': url,
        'title': title ?? '',
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 打开官方网页版（不带 URL，由原生侧使用固定首页）。
  ///
  /// 注意不能复用 [openInApp]：它对空 URL 直接返回 false（那是给
  /// 正文链接用的守卫），而网页版入口本来就没有 URL。
  Future<bool> openWebVersion() async {
    try {
      final ok = await _browser.invokeMethod<bool>('open');
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 打开应用内登录流程：加载官方 Web 端，用户手动完成手机号 + 短信
  /// 验证码登录后，原生轮询到凭证即反向回调并自动关闭页面。
  Future<bool> openLogin() async {
    try {
      final ok = await _browser.invokeMethod<bool>('login');
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 离屏静默检测官方 Web 端登录态（不打开任何可见页面）。
  ///
  /// 原生在后台加载一次网页版首页并读取 localStorage，结果仍经
  /// [setBrowserHandlers] 的 onAuthToken 回调送回（mode='peek'）。
  /// 返回 false 表示原生没接住（已有检测在进行 / 初始化失败），
  /// 调用方应自行复位等待态；返回 true 则结果由回调送达（含超时兜底）。
  Future<bool> peekWebLogin() async {
    try {
      final ok = await _browser.invokeMethod<bool>('peek');
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 清除 WebView 的 Cookie 与 DOM 存储（退出登录时联动调用），
  /// 否则下次打开网页版仍是旧的登录态。
  Future<void> clearWebData() async {
    try {
      await _browser.invokeMethod<void>('clearWebData');
    } on PlatformException {
      // 忽略。
    } on MissingPluginException {
      // 忽略。
    }
  }

  /// 注册浏览器反向回调。应用生命周期内只需调用一次（main.dart initState）。
  ///
  /// * [onAuthToken] —— 原生从网页端读到（或确认没读到）登录凭证；
  /// * [onExitToReading] —— 网页版顶栏点了「切换到阅读模式」，
  ///   应把底部导航切回搜索页。
  void setBrowserHandlers({
    required AuthTokenCallback onAuthToken,
    required void Function() onExitToReading,
  }) {
    _browser.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onAuthToken':
          final args = call.arguments;
          final payload = AuthTokenPayload(
            found: args is Map && args['found'] == true,
            token: args is Map ? (args['token']?.toString() ?? '') : '',
            authToken: args is Map ? (args['authToken']?.toString() ?? '') : '',
            mode: args is Map ? (args['mode']?.toString() ?? '') : '',
            keys: args is Map ? (args['keys']?.toString() ?? '') : '',
            diag: args is Map ? (args['diag']?.toString() ?? '') : '',
          );
          await onAuthToken(payload);
          return null;
        case 'exitToReading':
          onExitToReading();
          return null;
        default:
          throw MissingPluginException('未知方法：${call.method}');
      }
    });
  }
}

/// 原生浏览器容器回传的登录凭证。
///
/// [token] 与 [authToken] 是官方 Web 端 `flutter.UserInfo` 里的两个候选字段，
/// 以 [token] 优先（Authorization 头实际取值），由调用方用 parseJwt 挑选。
class AuthTokenPayload {
  const AuthTokenPayload({
    required this.found,
    required this.token,
    required this.authToken,
    required this.mode,
    this.keys = '',
    this.diag = '',
  });

  /// 是否检测到登录信息（false 表示用户关闭了登录页且未登录）。
  final bool found;

  /// 候选 1：`UserInfo.token` —— Authorization 头实际取值。
  final String token;

  /// 候选 2：`UserInfo.auth_token` —— 备用。
  final String authToken;

  /// 来源模式：`auth`（登录流程）、`web`（网页版静默同步）、
  /// `peek`（离屏静默检测，不打扰用户）。
  final String mode;

  /// 未找到凭证时，官方 Web 端 localStorage 的键名快照（原生已截断）。
  /// 用于在运行日志里诊断「官方改了键名导致读不到」这类漂移问题。
  final String keys;

  /// 未找到时的诊断信息（主键原始值摘要 / 解析异常），供运行日志定位。
  final String diag;
}

/// [NativeBridge.setBrowserHandlers] 的凭证回调签名。
typedef AuthTokenCallback = Future<void> Function(AuthTokenPayload payload);

/// 从系统文件选择器读回的备份文件。
class BackupFile {
  const BackupFile({required this.name, required this.content});

  /// 文件名（仅用于展示，可能是 URI 末段，不一定带扩展名）。
  final String name;

  /// 文件全文（UTF-8 解码后的 JSON 文本）。
  final String content;
}
