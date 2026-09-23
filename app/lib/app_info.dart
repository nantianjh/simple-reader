/// 应用标识信息 —— 全工程唯一出处。
///
/// [version] 需与 `pubspec.yaml` 的 `version:` 前缀手工保持一致：工程约定
/// 零第三方运行时依赖，因此不引入 `package_info_plus` 去读构建信息。
/// 集中在这里是为了避免"启动日志 / 关于 / 备份文件"各写一份版本号而漂移。
class AppInfo {
  AppInfo._();

  /// 应用显示名（与 AndroidManifest 的 android:label 一致）。
  static const String name = 'Simple阅读';

  /// 应用版本号（不含 build number）。
  static const String version = '1.9.7';

  /// 跨端识别用的稳定标识：备份文件的 `app` 字段与将来的网页版共用同值。
  static const String appId = 'simple-reader';

  /// 备份文件名的前缀。
  static const String backupFilePrefix = 'Simple阅读备份';
}
