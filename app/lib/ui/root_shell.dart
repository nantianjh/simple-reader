import 'package:flutter/material.dart';

import '../app_info.dart';
import '../data/data_revision.dart';
import '../data/local_store.dart';
import '../data/settings.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../util/app_log.dart';
import 'favorites_page.dart';
import 'me_page.dart';
import 'search_page.dart';
import 'shell_nav.dart';
import 'theme.dart';
import 'token_setup_page.dart';
import 'widgets/about_content.dart';
import 'widgets/brightness_aware.dart';
import 'widgets/update_notes.dart';

/// 应用外壳：负责鉴权分流与底部导航。
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  /// 本次会话是否已经检查过启动提示（防止鉴权状态抖动时重复弹）。
  bool _greeted = false;

  /// 进入主界面（阅读模式）后的一次性提示，**顺序固定**：
  /// 先「更新内容」（仅版本变了才弹），再首次的「关于」。
  ///
  /// 顺序不能反：全新安装时应当只弹「关于」一个框，若先跑「关于」流程，
  /// `firstRunDone` 会被置位，紧接着的版本判定就会把新用户误认成老用户升级，
  /// 一次进来吃两个弹窗。
  ///
  /// 「关于」的规则（v1.9.1）：自动弹出的功能导览改成「关于」（内容与
  /// 「我的 → 高级设置 → 关于」完全一致）；功能导览本身保留为手动入口。
  /// 只弹一次的标记是 `AppSettings.aboutIntroShown`，用的是**新键** ——
  /// 老用户（此前已看过导览）也会看到这一次「关于」。
  void _showStartupNoticesOnce() {
    if (_greeted) return;
    _greeted = true;

    // 读在 markFirstRunDone 之前：用它区分「全新安装」与「老用户升级」。
    final wasFirstRun = AppSettings.instance.firstRunDone;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _maybeShowUpdateNotes(wasFirstRun: wasFirstRun);

      // 能走到主界面就视为完成首次登录引导。
      await AppSettings.instance.markFirstRunDone();
      if (AppSettings.instance.aboutIntroShown) return;
      if (!mounted) return;
      log.i(LogTag.app, '首次进入主界面，展示「关于」提示页');
      // 先落标记再弹：用户中途返回/杀进程时不必再看一次。
      await AppSettings.instance.markAboutIntroShown();
      if (!mounted) return;
      await showAboutIntroDialog(context);
    });
  }

  /// 版本号变了才弹「更新内容」。
  ///
  /// 口径（用户 2026-09-22 定）：**每次版本号变更，首次启动弹一次**，
  /// 内容只讲用户能感知的变化（见 `Changelog` 的维护约定）。判定细节：
  ///
  /// * 本机记录的版本 = 当前版本 → 不弹；
  /// * 本机有记录且不同 → 弹出"比它新"的全部版本记录（跨版本升级不会漏）；
  /// * 本机没有记录（该键刚引入，或用户从没进过主界面）：
  ///   - [wasFirstRun] 为 true ⇒ 老用户升级上来，弹一次**当前版本**的记录；
  ///   - 否则 ⇒ 全新安装，"更新"无从谈起（首装用户看到的是「关于」），只记下版本号。
  ///
  /// 无论弹不弹都立刻记下当前版本：弹过就不再弹，中途杀进程也不会重复骚扰。
  Future<void> _maybeShowUpdateNotes({required bool wasFirstRun}) async {
    final store = LocalStore.instance;
    final current = AppInfo.version;
    final seen = store.readString(LocalStore.keyLastSeenVersion);
    if (seen == current) return;

    final freshInstall = seen == null && !wasFirstRun;
    await store.write(LocalStore.keyLastSeenVersion, current);

    if (freshInstall) {
      log.i(LogTag.app, '全新安装：记下版本 $current，不展示更新内容');
      return;
    }
    if (!mounted) return;
    log.i(LogTag.app, '展示更新内容：${seen ?? '（本机无记录）'} → $current');
    await showUpdateNotesDialog(
      context,
      fromVersion: seen,
      latestOnly: seen == null,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 包一层亮度依赖：页面配色全是静态语义色，系统在「跟随系统」模式下切换
    // 明暗时必须让本页重建，否则底部导航、主体区域会停在旧配色。
    return BrightnessAware(builder: (context, _) => _body(context));
  }

  Widget _body(BuildContext context) {
    final app = AppScope.of(context);

    // 首次使用且没有凭证：直接进配置页，避免用户对着空列表困惑。
    if (app.status == AuthStatus.initializing) {
      return const _SplashScreen();
    }
    if (app.status == AuthStatus.missing) {
      return const TokenSetupPage();
    }
    if (app.status == AuthStatus.verifying && !app.hasToken) {
      return const _SplashScreen();
    }

    _showStartupNoticesOnce();

    // 导航下标提到 [ShellNav]，「我的」页才能一键跳到收藏夹。
    return ValueListenableBuilder<int>(
      valueListenable: ShellNav.index,
      builder: (context, index, _) => ValueListenableBuilder<int>(
        // 数据导入会整体替换本机数据，而这三个页面各自在 State 里持有已抓取的
        // 列表、游标与选中态（不订阅那些 store）。版本号一变就换 Key 重建，
        // 页面重新按导入后的数据取数 —— 否则会出现"数据进去了、界面还是旧的"。
        valueListenable: DataRevision.instance.listenable,
        builder: (context, dataRev, _) => Scaffold(
          body: IndexedStack(
            index: index,
            children: [
              SearchPage(key: ValueKey('search-$dataRev')),
              FavoritesPage(key: ValueKey('favorites-$dataRev')),
              MePage(key: ValueKey('me-$dataRev')),
            ],
          ),
          bottomNavigationBar: Container(
            decoration: BoxDecoration(
              border:
                  Border(top: BorderSide(color: AppTheme.divider, width: 0.6)),
            ),
            child: BottomNavigationBar(
              currentIndex: index,
              onTap: ShellNav.go,
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.search_rounded, size: 21),
                  label: '搜索',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.star_border_rounded, size: 21),
                  label: '收藏',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.person_outline_rounded, size: 21),
                  label: '我的',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return BrightnessAware(
      builder: (context, _) => Scaffold(
        backgroundColor: AppTheme.cardBackground,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.manage_search_rounded, size: 46, color: AppTheme.accent),
              const SizedBox(height: 16),
              Text(
                'Simple阅读',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.inkPrimary,
                ),
              ),
              const SizedBox(height: 18),
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
