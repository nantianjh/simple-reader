import 'package:flutter/material.dart';

import '../data/settings.dart';
import '../platform/native_bridge.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../util/app_log.dart';
import '../util/format.dart';
import 'advanced_settings_page.dart';
import 'theme.dart';
import 'token_setup_page.dart';
import 'widgets/brightness_aware.dart';
import 'widgets/user_avatar.dart';

/// 「我的」页：凭证、账号状态、外观与主要入口。
///
/// 需求调整：诊断及其下方的本地数据 / 凭证操作 / 关于等设置项已收进
/// 「高级设置」二级页（[AdvancedSettingsPage]）；本页保留账号、凭证、
/// 外观、搜索四张卡，以及「切换到网页版」（需求明确要求留在本页）
/// 与「高级设置」两个入口。
class MePage extends StatefulWidget {
  const MePage({super.key});

  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  void _toast(String msg) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2, milliseconds: 200),
        ),
      );
  }

  Future<void> _replaceToken() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TokenSetupPage(onCompleted: () => Navigator.of(context).pop()),
      ),
    );
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------- 外观

  String _themeModeLabel(ThemeMode m) => switch (m) {
        ThemeMode.system => '跟随系统',
        ThemeMode.light => '浅色',
        ThemeMode.dark => '深色',
      };

  Future<void> _pickThemeMode() async {
    final current = AppSettings.instance.themeMode;
    final picked = await showDialog<ThemeMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('主题模式', style: TextStyle(fontSize: 17)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
            child: Text(
              '「跟随系统」会随系统的深色模式自动切换；'
              '手动选择后固定使用所选模式。',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: AppTheme.inkSecondary.withValues(alpha: 0.9),
              ),
            ),
          ),
          for (final m in ThemeMode.values)
            InkWell(
              onTap: () => Navigator.of(ctx).pop(m),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 10, 18, 10),
                child: Row(
                  children: [
                    Icon(
                      switch (m) {
                        ThemeMode.system => Icons.brightness_auto_outlined,
                        ThemeMode.light => Icons.light_mode_outlined,
                        ThemeMode.dark => Icons.dark_mode_outlined,
                      },
                      size: 19,
                      color: AppTheme.accent,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _themeModeLabel(m),
                        style: TextStyle(
                          fontSize: 14,
                          color: AppTheme.inkPrimary,
                          fontWeight:
                              m == current ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (m == current)
                      Icon(Icons.check_rounded,
                          size: 18, color: AppTheme.accent),
                  ],
                ),
              ),
            ),
        ],
      ),
    );

    if (picked == null || !mounted) return;
    await AppSettings.instance.setThemeMode(picked);
    log.i(LogTag.app, '主题模式切换为：${_themeModeLabel(picked)}');
  }

  // ---------------------------------------------------------------- 搜索

  Future<void> _manageBlockedKeywords() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => const _BlockedKeywordsDialog(),
    );
    if (mounted) setState(() {}); // 返回后刷新副标题里的计数
  }

  // -------------------------------------------------------- 网页版与高级设置

  /// 应用内打开官方 Web 端（原生 WebView 全屏承载）。
  /// 返回键或在网页版里点「阅读模式」即可回到本应用。
  Future<void> _openWebVersion() async {
    final ok = await NativeBridge.instance.openWebVersion();
    if (!mounted) return;
    if (!ok) _toast('无法打开内置浏览器页面');
  }

  /// 进入「高级设置」二级页（诊断、本地数据、凭证操作与关于）。
  Future<void> _openAdvancedSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AdvancedSettingsPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 包一层亮度依赖：本页配色全是静态语义色，系统在「跟随系统」模式下
    // 切换明暗时必须重建，否则已挂载的卡片会停在旧主题。
    return BrightnessAware(builder: (context, _) => _contents(context));
  }

  Widget _contents(BuildContext context) {
    final app = AppScope.of(context);

    return Scaffold(
      backgroundColor: AppTheme.pageBackground,
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: [
          _accountCard(app),
          const SizedBox(height: 14),
          _tokenCard(app),
          const SizedBox(height: 14),
          AnimatedBuilder(
            animation: AppSettings.instance,
            builder: (context, _) => _appearanceCard(),
          ),
          const SizedBox(height: 14),
          AnimatedBuilder(
            animation: AppSettings.instance,
            builder: (context, _) => _searchCard(),
          ),
          const SizedBox(height: 14),
          _entriesCard(),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 账号卡

  Widget _accountCard(AppState app) {
    final me = app.currentUser;
    final ready = app.status == AuthStatus.ready;

    return _card(
      child: Row(
        children: [
          if (me != null)
            UserAvatar(user: me, size: 50)
          else
            Container(
              width: 50,
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.surfaceMuted,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.person_outline_rounded,
                  size: 24, color: AppTheme.inkTertiary),
            ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  me != null ? me.nickname : '未获取到账号信息',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.inkPrimary,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    _statusDot(ready),
                    const SizedBox(width: 5),
                    Text(
                      _statusText(app),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: ready ? AppTheme.success : AppTheme.inkSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                if (app.userIsCached && me != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    '（昵称为本地缓存快照）',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.inkTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusDot(bool ok) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: ok ? AppTheme.success : AppTheme.inkDisabled,
        shape: BoxShape.circle,
      ),
    );
  }

  String _statusText(AppState app) => switch (app.status) {
        AuthStatus.initializing => '正在初始化…',
        AuthStatus.missing => '尚未配置凭证',
        AuthStatus.verifying => '正在校验凭证…',
        AuthStatus.ready => '凭证有效，可使用',
        AuthStatus.invalid => '凭证已失效，请重新配置',
      };

  // -------------------------------------------------------------- 凭证卡
  //
  // 需求调整：凭证框瘦身，只保留到期时间一行。
  // （用户 ID / 剩余有效期 / 本机保存于 / token 掩码都已移除；
  // 失效状态由账号卡的状态行与顶部 AuthBanner 承担，更换/清除入口
  // 在「高级设置」页里。）

  Widget _tokenCard(AppState app) {
    final jwt = app.jwt;

    if (!app.hasToken) {
      return _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cardTitle('访问凭证'),
            const SizedBox(height: 10),
            Text(
              '还没有配置 token。',
              style: TextStyle(fontSize: 13.5, color: AppTheme.inkSecondary),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _replaceToken,
                child: const Text('去配置'),
              ),
            ),
          ],
        ),
      );
    }

    return _card(
      child: Row(
        children: [
          Icon(Icons.event_available_outlined,
              size: 17, color: AppTheme.inkTertiary),
          const SizedBox(width: 9),
          Text(
            '到期时间',
            style: TextStyle(fontSize: 12.5, color: AppTheme.inkTertiary),
          ),
          const Spacer(),
          Text(
            jwt?.expiresAt != null ? formatDateTime(jwt!.expiresAt) : '未知',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: jwt != null && jwt.isExpiringSoon
                  ? AppTheme.warning
                  : AppTheme.inkPrimary,
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- 外观卡

  Widget _appearanceCard() {
    final settings = AppSettings.instance;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle('外观'),
          const SizedBox(height: 4),
          _actionRow(
            icon: Icons.contrast_rounded,
            title: '深色模式',
            subtitle:
                '${_themeModeLabel(settings.themeMode)} · 跟随系统时随系统深色模式自动切换',
            onTap: _pickThemeMode,
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- 搜索卡

  Widget _searchCard() {
    final n = AppSettings.instance.blockedKeywords.length;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle('搜索'),
          const SizedBox(height: 4),
          _actionRow(
            icon: Icons.block_rounded,
            title: '屏蔽关键词',
            subtitle: n == 0
                ? '正文包含关键词的动态将在搜索结果中隐藏'
                : '已设置 $n 个 · 完整包含即隐藏',
            onTap: _manageBlockedKeywords,
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------- 入口卡
  //
  // 「切换到网页版」按需求保留在「我的」页；其余设置项都在「高级设置」里。

  Widget _entriesCard() {
    return _card(
      child: Column(
        children: [
          _actionRow(
            icon: Icons.language_rounded,
            title: '切换到网页版',
            subtitle: '应用内打开官方 Web 端，随时可一键切回阅读模式',
            onTap: _openWebVersion,
          ),
          const Divider(height: 18),
          _actionRow(
            icon: Icons.tune_rounded,
            title: '高级设置',
            subtitle: '诊断、本地数据、凭证操作与关于',
            onTap: _openAdvancedSettings,
          ),
        ],
      ),
    );
  }

  Widget _actionRow({
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
    Widget? trailing,
    bool destructive = false,
  }) {
    final enabled = onTap != null;
    final color = destructive ? AppTheme.danger : AppTheme.inkPrimary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(
              icon,
              size: 19,
              color: enabled
                  ? (destructive ? AppTheme.danger : AppTheme.accent)
                  : AppTheme.inkDisabled,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: enabled ? color : AppTheme.inkTertiary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.inkTertiary,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) trailing,
            if (enabled && trailing == null)
              Icon(Icons.chevron_right_rounded,
                  size: 19, color: AppTheme.inkDisabled),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 基础件

  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.divider, width: 0.6),
      ),
      child: child,
    );
  }

  Widget _cardTitle(String t) => Text(
        t,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppTheme.inkSecondary,
        ),
      );
}

/// 屏蔽关键词管理弹窗：添加 / 删除，实时生效。
///
/// 「完整匹配」= 动态正文**完整包含**该关键词时整条隐藏（大小写不敏感），
/// 不做分词或模糊匹配；只作用于搜索结果，收藏与合集不受影响。
class _BlockedKeywordsDialog extends StatefulWidget {
  const _BlockedKeywordsDialog();

  @override
  State<_BlockedKeywordsDialog> createState() => _BlockedKeywordsDialogState();
}

class _BlockedKeywordsDialogState extends State<_BlockedKeywordsDialog> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final added = await AppSettings.instance.addBlockedKeyword(_input.text);
    if (!mounted) return;
    if (added) {
      _input.clear();
      _focus.requestFocus();
    } else {
      FocusScope.of(context).unfocus();
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('关键词为空或已存在'),
          duration: Duration(seconds: 2),
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    // 增删关键词都走 AppSettings.notifyListeners，但本 State 此前从未订阅它
    // —— build 里读到的列表永远是旧值，表现为"添加/删除后界面不重绘"。
    // 这里订阅设置变更，任何增删立即重画关键词墙。
    return ListenableBuilder(
      listenable: AppSettings.instance,
      builder: (context, _) => _buildDialog(context),
    );
  }

  Widget _buildDialog(BuildContext context) {
    final keywords = AppSettings.instance.blockedKeywords;

    return AlertDialog(
      title: const Text('屏蔽关键词', style: TextStyle(fontSize: 17)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '搜索结果的动态正文完整包含任一关键词时，整条隐藏'
              '（大小写不敏感）。只作用于搜索，收藏与合集不受影响。',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: AppTheme.inkTertiary,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    focusNode: _focus,
                    onSubmitted: (_) => _add(),
                    textInputAction: TextInputAction.done,
                    style: TextStyle(fontSize: 14, color: AppTheme.inkPrimary),
                    decoration: InputDecoration(
                      hintText: '输入关键词后回车或点添加',
                      hintStyle:
                          TextStyle(fontSize: 12.5, color: AppTheme.inkTertiary),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _add,
                  child: const Text('添加'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (keywords.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Center(
                  child: Text(
                    '还没有屏蔽关键词',
                    style: TextStyle(
                        fontSize: 12.5, color: AppTheme.inkTertiary),
                  ),
                ),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final k in keywords)
                        Container(
                          padding:
                              const EdgeInsets.fromLTRB(12, 6, 6, 6),
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceMuted,
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 200),
                                child: Text(
                                  k,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: AppTheme.inkPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 2),
                              InkWell(
                                onTap: () => AppSettings.instance
                                    .removeBlockedKeyword(k),
                                borderRadius: BorderRadius.circular(9),
                                child: Padding(
                                  padding: const EdgeInsets.all(3),
                                  child: Icon(Icons.close_rounded,
                                      size: 13, color: AppTheme.danger),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (keywords.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '变更立即生效：新增后正在浏览的结果会移除命中项；'
                '删除关键词后，此前被隐藏的内容需下拉刷新重新抓取才会出现。',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: AppTheme.inkTertiary,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }
}
