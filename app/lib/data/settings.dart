import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import 'local_store.dart';

/// 内容缓存的保留期限。
///
/// [days] 语义：0 表示完全不缓存；-1 表示不自动过期。
enum CacheRetention {
  off(0, '不缓存', '每次都从网络读取，不落盘'),
  day1(1, '1 天', '当天抓取的内容保留 1 天'),
  day3(3, '3 天', ''),
  day7(7, '7 天', '默认，兼顾省流量与新鲜度'),
  day30(30, '30 天', ''),
  forever(-1, '永久保留', '不自动清理，只能手动清空');

  const CacheRetention(this.days, this.label, this.description);

  final int days;
  final String label;
  final String description;

  bool get enabled => days != 0;

  static CacheRetention fromDays(int days) {
    for (final v in CacheRetention.values) {
      if (v.days == days) return v;
    }
    return CacheRetention.day7;
  }
}

/// 应用设置。
///
/// 用 [ChangeNotifier] 单例承载，页面通过 `AnimatedBuilder` 订阅，
/// 与工程内既有的状态管理方式保持一致（不引入 provider）。
///
/// v1.7.2 新增：主题模式（跟随系统 / 浅色 / 深色）与搜索屏蔽关键词。
/// v1.8.x 新增：正文链接在应用内打开的开关。
/// v1.9.6 新增：互动按钮左置/右置。
class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  static const int _defaultRetentionDays = 7;

  int _retentionDays = _defaultRetentionDays;
  bool _askResumeOnSearch = true;
  bool _showReadMarkers = true;
  ThemeMode _themeMode = ThemeMode.system;
  List<String> _blockedKeywords = const <String>[];
  bool _openLinksInApp = true;
  bool _interactionButtonsOnRight = true;
  bool _firstRunDone = false;
  bool _readingIntroShown = false;
  bool _collectionsIntroShown = false;
  bool _aboutIntroShown = false;

  /// 已抓取内容的缓存保留期限（天）。0 = 不缓存，-1 = 永久。
  int get retentionDays => _retentionDays;
  CacheRetention get retention => CacheRetention.fromDays(_retentionDays);

  /// 搜索命中续读点时是否弹窗询问。
  bool get askResumeOnSearch => _askResumeOnSearch;

  /// 列表中是否把已读条目标记出来。
  bool get showReadMarkers => _showReadMarkers;

  /// 主题模式：跟随系统 / 浅色 / 深色。
  ThemeMode get themeMode => _themeMode;

  /// 搜索屏蔽关键词（不可变视图，修改请走 [addBlockedKeyword] 等方法）。
  List<String> get blockedKeywords => List.unmodifiable(_blockedKeywords);

  /// 正文/分享等链接是否默认用应用内 WebView 打开（关闭则回退系统浏览器）。
  bool get openLinksInApp => _openLinksInApp;

  /// 列表卡片底部的**互动按钮（点赞 / 评论 / 收藏）是否放在右侧**。
  ///
  /// 2026-09-22 需求：默认右置 —— 右手单手拿机时拇指正好落在右下角；
  /// 关闭则回到左侧（旧版布局）。操作类按钮（展开全文 / 折叠）永远在对侧。
  bool get interactionButtonsOnRight => _interactionButtonsOnRight;

  /// 首次引导是否已完成（登录成功后置位）。
  ///
  /// 未置位时凭证配置页会带欢迎引导、并把「账号登录」标成推荐路径。
  bool get firstRunDone => _firstRunDone;

  /// 功能导览是否已展示过（首次进入阅读模式时展示一次，看完置位）。
  bool get readingIntroShown => _readingIntroShown;

  /// 「收藏的合集」说明页是否已展示过（首次进入该视图时弹一次，看过置位）。
  ///
  /// 该说明页解释「服务端拿不到收藏的合集列表、只能从收藏动态反解自建」，
  /// 并给出「先在官方端为每个合集收藏至少一条动态」的使用前提。
  bool get collectionsIntroShown => _collectionsIntroShown;

  /// 「关于」提示页是否已展示过（首次登录进入主界面时弹一次）。
  ///
  /// 内容与「我的 → 高级设置 → 关于」完全一致：这是什么工具 + 请求边界与
  /// 滥用后果。v1.9.1 起用它替代原先自动弹出的功能导览（导览改为手动查看）。
  bool get aboutIntroShown => _aboutIntroShown;

  Future<void> load() async {
    final m = LocalStore.instance.readMap(LocalStore.keySettings);
    final days = m['cacheRetentionDays'];
    if (days is int) _retentionDays = days;
    final ask = m['askResumeOnSearch'];
    if (ask is bool) _askResumeOnSearch = ask;
    final mark = m['showReadMarkers'];
    if (mark is bool) _showReadMarkers = mark;
    _themeMode = _themeModeFromStored(m['themeMode']);
    final keywords = m['blockedKeywords'];
    if (keywords is List) {
      _blockedKeywords = List<String>.of(
        keywords.whereType<String>().map((e) => e.trim()).where((e) => e.isNotEmpty),
      );
    }
    final inApp = m['openLinksInApp'];
    if (inApp is bool) _openLinksInApp = inApp;
    final interactRight = m['interactionButtonsOnRight'];
    if (interactRight is bool) _interactionButtonsOnRight = interactRight;
    final firstRun = m['firstRunDone'];
    if (firstRun is bool) _firstRunDone = firstRun;
    final intro = m['readingIntroShown'];
    if (intro is bool) _readingIntroShown = intro;
    final colIntro = m['collectionsIntroShown'];
    if (colIntro is bool) _collectionsIntroShown = colIntro;
    final aboutIntro = m['aboutIntroShown'];
    if (aboutIntro is bool) _aboutIntroShown = aboutIntro;
    notifyListeners();
  }

  Future<void> setRetention(CacheRetention v) async {
    if (_retentionDays == v.days) return;
    _retentionDays = v.days;
    notifyListeners();
    await _persist();
  }

  Future<void> setAskResumeOnSearch(bool v) async {
    if (_askResumeOnSearch == v) return;
    _askResumeOnSearch = v;
    notifyListeners();
    await _persist();
  }

  Future<void> setShowReadMarkers(bool v) async {
    if (_showReadMarkers == v) return;
    _showReadMarkers = v;
    notifyListeners();
    await _persist();
  }

  Future<void> setThemeMode(ThemeMode v) async {
    if (_themeMode == v) return;
    _themeMode = v;
    notifyListeners();
    await _persist();
  }

  Future<void> setOpenLinksInApp(bool v) async {
    if (_openLinksInApp == v) return;
    _openLinksInApp = v;
    notifyListeners();
    await _persist();
  }

  Future<void> setInteractionButtonsOnRight(bool v) async {
    if (_interactionButtonsOnRight == v) return;
    _interactionButtonsOnRight = v;
    notifyListeners();
    await _persist();
  }

  /// 标记首次引导完成（登录成功时调用；幂等）。
  Future<void> markFirstRunDone() async {
    if (_firstRunDone) return;
    _firstRunDone = true;
    await _persist();
  }

  /// 标记功能导览已看过（幂等）。置位后不再自动弹出。
  Future<void> markReadingIntroShown() async {
    if (_readingIntroShown) return;
    _readingIntroShown = true;
    await _persist();
  }

  /// 标记「收藏的合集」说明页已看过（幂等）。置位后不再自动弹出。
  Future<void> markCollectionsIntroShown() async {
    if (_collectionsIntroShown) return;
    _collectionsIntroShown = true;
    await _persist();
  }

  /// 标记「关于」提示页已看过（幂等）。置位后不再自动弹出。
  Future<void> markAboutIntroShown() async {
    if (_aboutIntroShown) return;
    _aboutIntroShown = true;
    await _persist();
  }

  /// 新增一个屏蔽关键词。已存在（忽略大小写）或为空时不写入。
  /// 返回是否真的新增了。
  Future<bool> addBlockedKeyword(String raw) async {
    final k = raw.trim();
    if (k.isEmpty) return false;
    if (_blockedKeywords.any((e) => e.toLowerCase() == k.toLowerCase())) {
      return false;
    }
    _blockedKeywords = [..._blockedKeywords, k];
    notifyListeners();
    await _persist();
    return true;
  }

  /// 删除一个屏蔽关键词。
  Future<void> removeBlockedKeyword(String keyword) async {
    final next = List<String>.of(_blockedKeywords)..remove(keyword);
    if (next.length == _blockedKeywords.length) return;
    _blockedKeywords = next;
    notifyListeners();
    await _persist();
  }

  /// 正文是否命中屏蔽词：完整包含任一关键词即命中（大小写不敏感）。
  ///
  /// 「完整匹配」指的是整段关键词原样出现在正文里，不做分词或模糊匹配。
  bool matchesBlockedKeyword(String content) {
    if (_blockedKeywords.isEmpty || content.isEmpty) return false;
    final lower = content.toLowerCase();
    for (final k in _blockedKeywords) {
      if (lower.contains(k.toLowerCase())) return true;
    }
    return false;
  }

  static ThemeMode _themeModeFromStored(dynamic v) {
    if (v is String) {
      switch (v) {
        case 'light':
          return ThemeMode.light;
        case 'dark':
          return ThemeMode.dark;
      }
    }
    return ThemeMode.system;
  }

  static String _storeThemeMode(ThemeMode v) => switch (v) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };

  Future<void> _persist() => LocalStore.instance.write(LocalStore.keySettings, {
        'cacheRetentionDays': _retentionDays,
        'askResumeOnSearch': _askResumeOnSearch,
        'showReadMarkers': _showReadMarkers,
        'themeMode': _storeThemeMode(_themeMode),
        'blockedKeywords': _blockedKeywords,
        'openLinksInApp': _openLinksInApp,
        'interactionButtonsOnRight': _interactionButtonsOnRight,
        'firstRunDone': _firstRunDone,
        'readingIntroShown': _readingIntroShown,
        'collectionsIntroShown': _collectionsIntroShown,
        'aboutIntroShown': _aboutIntroShown,
      });
}
