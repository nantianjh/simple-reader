import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_info.dart';
import 'auth/jwt_utils.dart';
import 'data/content_cache.dart';
import 'data/favourite_collections.dart';
import 'data/local_store.dart';
import 'data/reading_positions.dart';
import 'data/search_history.dart';
import 'data/settings.dart';
import 'data/user_remarks.dart';
import 'platform/native_bridge.dart';
import 'state/app_scope.dart';
import 'state/app_state.dart';
import 'state/subscription_scanner.dart';
import 'ui/root_shell.dart';
import 'ui/shell_nav.dart';
import 'ui/theme.dart';
import 'util/app_log.dart';

/// 全局导航键：原生反向回调（凭证回传、切回阅读模式）发生时
/// Flutter 侧可能停在任意页面，用它拿到 ScaffoldMessenger 做提示。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  // 日志系统要在第一时间可用：它同时接管 Flutter 与异步的全局异常，
  // 这样即便启动流程中途抛错，也能在「我的 → 运行日志」里看到现场。
  WidgetsFlutterBinding.ensureInitialized();
  _installErrorHooks();
  log.i(LogTag.app, '======== 应用启动（v${AppInfo.version}）========');
  await AppLog.instance.restore();

  // 竖屏为主：这是一个检索与阅读工具，横屏收益有限。
  SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // 本地数据全部预读进内存，之后 UI 层同步访问，不必到处 await。
  await LocalStore.instance.loadAll();
  await AppSettings.instance.load();
  await SearchHistory.instance.load();
  await ReadingPositionStore.instance.load();
  await FavouriteCollectionsStore.instance.load();
  await UserRemarksStore.instance.load();
  log.i(
    LogTag.app,
    '本地数据就绪：保留期=${AppSettings.instance.retention.label}，'
    '搜索历史=${SearchHistory.instance.length} 条，'
    '续读点=${ReadingPositionStore.instance.count} 个，'
    '本机收藏合集=${FavouriteCollectionsStore.instance.length} 个，'
    '用户备注=${UserRemarksStore.instance.length} 条，'
    '屏蔽词=${AppSettings.instance.blockedKeywords.length} 个，'
    '主题=${AppSettings.instance.themeMode.name}',
  );
  // 启动时按保留期限清理过期缓存（保留期设为「不缓存」时即全量清空）。
  await ContentCache.instance.purgeExpired();

  // 状态栏初值按启动时的实际明暗设置一次；后续随主题模式在根组件里更新。
  AppTheme.isDark =
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark;
  AppTheme.applyStatusBarStyle();

  runApp(const SimpleSearchApp());
  log.i(LogTag.app, '界面已挂载');
}

/// 全局异常捕获：让未处理的错误也进入运行日志，而不是只出现在 logcat 里。
void _installErrorHooks() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    log.exception(
      LogTag.app,
      'Flutter 框架异常',
      details.exception,
      details.stack,
    );
    previous?.call(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    log.exception(LogTag.app, '未捕获的异步异常', error, stack);
    return true;
  };
}

class SimpleSearchApp extends StatefulWidget {
  const SimpleSearchApp({super.key});

  @override
  State<SimpleSearchApp> createState() => _SimpleSearchAppState();
}

class _SimpleSearchAppState extends State<SimpleSearchApp> {
  late final AppState _state;

  @override
  void initState() {
    super.initState();
    _state = AppState();
    // 启动即读取本地凭证并校验，UI 侧按 AuthStatus 分流；
    // 校验通过后顺带冷启动扫描订阅合集（见 [_bootstrapAndScan]）。
    unawaited(_bootstrapAndScan());
    // 原生浏览器容器的反向回调：网页登录凭证 / 切回阅读模式。
    _registerBrowserHandlers();
  }

  /// 凭证校验 → 订阅合集扫描。
  ///
  /// 扫描只在凭证就绪时进行；串行逐个拉取订阅合集的最新一页，
  /// 发现有新动态就在合集名称右侧标红点。整个过程在后台进行，
  /// 不阻塞首帧，也不弹任何提示（结果以红点呈现）。
  Future<void> _bootstrapAndScan() async {
    await _state.bootstrap();
    if (!_state.isReady) return;
    await SubscriptionScanner(tokenProvider: () => _state.token).scan(
      ownerUserId: _state.currentUser?.id ?? _state.jwt?.userId ?? '',
    );
  }

  /// 应用内登录 / 网页版静默同步 / 离屏检测的统一收口。
  ///
  /// 原生 WebView 从官方 Web 端读到 `flutter.UserInfo` 后回传两个候选
  /// 字段（token / auth_token），这里用既有的 JWT 解析挑选出第一个
  /// 合法的，然后走与手工粘贴完全相同的 [AppState.loginWithToken]
  /// 链路——校验通过后 status 变 ready，RootShell 自动切到主界面，
  /// 全程无需用户再操作。
  ///
  /// payload.mode 区分来源：
  /// * `auth` —— 登录页回传（登录页已自动关闭）；
  /// * `web`  —— 网页版加载完成时的静默同步；
  /// * `peek` —— 凭证配置页触发的离屏检测（不打扰用户）。
  Future<void> _onAuthToken(AuthTokenPayload payload) async {
    _state.setWebLoginWaiting(false);
    _state.setWebPeeking(false);

    if (!payload.found) {
      final keysHint =
          payload.keys.isEmpty ? '' : '，官方 localStorage 键：${payload.keys}';
      final diagHint =
          payload.diag.isEmpty ? '' : '｜诊断：${payload.diag}';
      if (payload.mode == 'peek') {
        // 离屏检测读不到属预期内（网页端本就没登录过），静默收场。
        log.i(LogTag.auth, '离屏检测：网页端无登录态$keysHint$diagHint');
        return;
      }
      log.i(LogTag.auth, '网页登录已关闭，未带回凭证$keysHint$diagHint');
      return;
    }

    String? picked;
    for (final raw in [payload.token, payload.authToken]) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      final info = parseJwt(t);
      if (info.valid && !info.isExpired) {
        picked = t;
        break;
      }
    }
    if (picked == null) {
      log.w(LogTag.auth, '网页回传的凭证本地校验未通过（来源=${payload.mode}）');
      _showGlobalToast('网页凭证无效，请重试或改用手工粘贴');
      return;
    }

    if (_state.token == picked && _state.isReady) {
      log.d(LogTag.auth, '网页凭证与本机一致，无需重复登录');
      return;
    }

    log.i(LogTag.auth, '收到网页登录凭证（来源=${payload.mode}），开始校验…');
    final ok = await _state.loginWithToken(picked);
    if (!mounted) return;
    if (ok) {
      _showGlobalToast(switch (payload.mode) {
        'auth' => '登录成功',
        'peek' => '已自动同步网页登录状态',
        _ => '已同步网页登录状态',
      });
    } else {
      _showGlobalToast(_state.errorMessage ?? '网页凭证校验未通过');
    }
  }

  void _registerBrowserHandlers() {
    NativeBridge.instance.setBrowserHandlers(
      onAuthToken: _onAuthToken,
      onExitToReading: () => ShellNav.go(ShellNav.search),
    );
  }

  void _showGlobalToast(String msg) {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    ScaffoldMessenger.maybeOf(ctx)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 主题模式变化（手动切换 / 跟随系统时系统明暗变化）都要重建 MaterialApp，
    // 同时同步 AppTheme.isDark，让组件层引用的语义色一起切换。
    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (context, _) {
        final mode = AppSettings.instance.themeMode;
        final platformDark =
            MediaQuery.platformBrightnessOf(context) == Brightness.dark;
        AppTheme.isDark = switch (mode) {
          ThemeMode.light => false,
          ThemeMode.dark => true,
          ThemeMode.system => platformDark,
        };
        AppTheme.applyStatusBarStyle();

        return AppScope(
          state: _state,
          child: MaterialApp(
            title: 'Simple阅读',
            debugShowCheckedModeBanner: false,
            navigatorKey: appNavigatorKey,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: mode,
            home: const RootShell(),
            builder: (context, child) {
              // 锁定文字缩放上限，避免系统超大字号把列表布局挤坏。
              final mq = MediaQuery.of(context);
              final scale = mq.textScaler.clamp(
                minScaleFactor: 0.9,
                maxScaleFactor: 1.25,
              );
              return MediaQuery(
                data: mq.copyWith(textScaler: scale),
                child: child ?? const SizedBox.shrink(),
              );
            },
          ),
        );
      },
    );
  }
}
