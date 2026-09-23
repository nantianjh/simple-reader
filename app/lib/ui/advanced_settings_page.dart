import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../data/content_cache.dart';
import '../data/reading_positions.dart';
import '../data/search_history.dart';
import '../data/settings.dart';
import '../platform/native_bridge.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../util/app_log.dart';
import '../util/format.dart';
import 'log_page.dart';
import 'feature_tour.dart';
import 'theme.dart';
import 'token_setup_page.dart';
import 'widgets/about_content.dart';
import 'widgets/brightness_aware.dart';
import 'widgets/update_notes.dart';

/// 「我的 → 高级设置」二级页：诊断、本地数据、凭证操作与关于。
///
/// 需求调整：原「我的」页里诊断卡及其下方的本地数据 / 操作 / 关于四张卡
/// 全部收进本页（「切换到网页版」除外，仍留在「我的」页）。
class AdvancedSettingsPage extends StatefulWidget {
  const AdvancedSettingsPage({super.key});

  @override
  State<AdvancedSettingsPage> createState() => _AdvancedSettingsPageState();
}

class _AdvancedSettingsPageState extends State<AdvancedSettingsPage> {
  bool _busy = false;

  StorageStats _stats = StorageStats.empty;
  int _historyCount = 0;
  int _readPosCount = 0;

  /// 备份导出/导入进行中（两个入口共用，避免并发写同一份数据）。
  bool _backupBusy = false;

  /// 最近一次导出的落点，展示在导出行的副标题上，方便用户去取文件。
  String? _lastExportPath;

  @override
  void initState() {
    super.initState();
    _refreshStats();
  }

  Future<void> _refreshStats() async {
    final stats = await ContentCache.instance.stats();
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _historyCount = SearchHistory.instance.length;
      _readPosCount = ReadingPositionStore.instance.count;
    });
  }

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

  Future<void> _revalidate() async {
    setState(() => _busy = true);
    final app = AppScope.read(context);
    final ok = await app.revalidate();
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(ok ? '凭证有效' : (app.errorMessage ?? '校验未通过'));
  }

  Future<void> _replaceToken() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TokenSetupPage(onCompleted: () => Navigator.of(context).pop()),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除凭证', style: TextStyle(fontSize: 17)),
        content: const Text(
          '将从本机删除已保存的 token，并同步清除应用内网页的登录状态。'
          '删除后需要重新登录才能继续使用。',
          style: TextStyle(fontSize: 14, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // 网页数据与 token 一起清：否则下次打开网页版仍是旧的登录态。
    await NativeBridge.instance.clearWebData();
    await AppScope.read(context).logout();
  }

  Future<bool> _confirm({
    required String title,
    required String content,
    required String action,
  }) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 17)),
        content: Text(content, style: const TextStyle(fontSize: 13.5, height: 1.6)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: Text(action),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  // ------------------------------------------------------------ 本地数据

  Future<void> _pickRetention() async {
    final current = AppSettings.instance.retention;
    final picked = await showDialog<CacheRetention>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('缓存保留期限', style: TextStyle(fontSize: 17)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
            child: Text(
              '已抓取的内容会按请求缓存到本机。期限内再次访问同一页时直接读本地，'
              '不再发起请求；超期的文件会被自动清理。',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: AppTheme.inkSecondary.withValues(alpha: 0.9),
              ),
            ),
          ),
          for (final v in CacheRetention.values)
            InkWell(
              onTap: () => Navigator.of(ctx).pop(v),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 10, 18, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            v.label,
                            style: TextStyle(
                              fontSize: 14,
                              color: AppTheme.inkPrimary,
                            ),
                          ),
                          if (v.description.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              v.description,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: AppTheme.inkTertiary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (v == current)
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
    await AppSettings.instance.setRetention(picked);
    final removed = await ContentCache.instance.purgeExpired();
    if (!mounted) return;
    await _refreshStats();
    _toast(removed > 0 ? '已清理 $removed 项过期缓存' : '设置已保存');
  }

  Future<void> _clearCache() async {
    final ok = await _confirm(
      title: '清空内容缓存',
      content: '将删除本机缓存的全部已抓取内容（${_stats.count} 项，${_stats.readable}）。'
          '下次访问会重新从网络读取。阅读存档与搜索历史不受影响。',
      action: '清空',
    );
    if (!ok) return;
    final removed = await ContentCache.instance.clearAll();
    log.i(LogTag.cache, '用户清空内容缓存：$removed 项');
    if (!mounted) return;
    await _refreshStats();
    _toast('已清空 $removed 项缓存');
  }

  Future<void> _clearHistory() async {
    if (_historyCount == 0) return;
    final ok = await _confirm(
      title: '清空搜索历史',
      content: '将删除搜索框保留的 $_historyCount 条历史关键词。',
      action: '清空',
    );
    if (!ok) return;
    await SearchHistory.instance.clear();
    log.i(LogTag.app, '用户清空搜索历史：$_historyCount 条');
    if (!mounted) return;
    await _refreshStats();
    _toast('已清空搜索历史');
  }

  Future<void> _clearReadPositions() async {
    if (_readPosCount == 0) return;
    final ok = await _confirm(
      title: '清除阅读存档',
      content: '将删除 $_readPosCount 个续读点。清除后再次搜索同一关键词不会再提示续读。',
      action: '清除',
    );
    if (!ok) return;
    await ReadingPositionStore.instance.clear();
    log.i(LogTag.read, '用户清除阅读存档：$_readPosCount 个续读点');
    if (!mounted) return;
    await _refreshStats();
    _toast('已清除阅读存档');
  }

  // -------------------------------------------------------------- 诊断

  Future<void> _openLogs() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const LogPage()),
    );
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);

    // 包一层亮度依赖：本页配色全是静态语义色，不重建就会停在旧主题。
    return BrightnessAware(builder: (context, _) => _contents(app));
  }

  Widget _contents(AppState app) {
    return Scaffold(
      backgroundColor: AppTheme.pageBackground,
      appBar: AppBar(title: const Text('高级设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: [
          AnimatedBuilder(
            animation: AppSettings.instance,
            builder: (context, _) => _diagCard(),
          ),
          const SizedBox(height: 14),
          AnimatedBuilder(
            animation: AppSettings.instance,
            builder: (context, _) => _dataCard(),
          ),
          const SizedBox(height: 14),
          _backupCard(),
          const SizedBox(height: 14),
          AnimatedBuilder(
            animation: AppSettings.instance,
            builder: (context, _) => _actionsCard(app),
          ),
          const SizedBox(height: 14),
          _aboutCard(),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 诊断
  //
  // 运行日志（应用内 logcat）：把网络请求、缓存命中、翻页与续读决策、
  // 以及所有异常都落到这里，出问题时不必接电脑抓 logcat。
  //
  // 二级页每次进入都重新构建，直接读一次计数即可，无须订阅 AppLog
  // （订阅会让整页跟着每一次日志写入重建）。
  Widget _diagCard() {
    final lines = log.length;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle('诊断'),
          const SizedBox(height: 4),
          _actionRow(
            icon: Icons.receipt_long_outlined,
            title: '运行日志',
            subtitle: lines == 0
                ? '应用内 logcat：网络、缓存、翻页、续读与异常'
                : '当前 $lines 行'
                    '${log.dropped > 0 ? '（已丢弃 ${log.dropped} 行）' : ''}',
            onTap: _openLogs,
          ),
          const Divider(height: 18),
          SwitchListTile(
            value: log.mirrorDebug,
            onChanged: (v) {
              log.mirrorDebug = v;
              setState(() {});
            },
            title: Text('调试级日志也写入系统日志',
                style: TextStyle(fontSize: 14, color: AppTheme.inkPrimary)),
            subtitle: Text(
              '开启后除应用内查看外，adb logcat 里也能看到调试级记录',
              style: TextStyle(fontSize: 12, color: AppTheme.inkTertiary),
            ),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- 本地数据

  Widget _dataCard() {
    final settings = AppSettings.instance;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle('本地数据'),
          const SizedBox(height: 4),
          _actionRow(
            icon: Icons.sd_storage_outlined,
            title: '内容缓存保留期限',
            subtitle: settings.retention.enabled
                ? '${settings.retention.label} · 已缓存 ${_stats.count} 项（${_stats.readable}）'
                : '已关闭 · 不缓存任何内容',
            onTap: _pickRetention,
          ),
          const Divider(height: 18),
          _actionRow(
            icon: Icons.delete_sweep_outlined,
            title: '清空内容缓存',
            subtitle: '删除本机缓存的已抓取内容',
            destructive: true,
            onTap: _stats.count == 0 ? null : _clearCache,
          ),
          const Divider(height: 18),
          _actionRow(
            icon: Icons.history_rounded,
            title: '清空搜索历史',
            subtitle: '搜索框保留 $_historyCount 条历史关键词',
            destructive: true,
            onTap: _historyCount == 0 ? null : _clearHistory,
          ),
          const Divider(height: 18),
          _actionRow(
            icon: Icons.bookmark_remove_outlined,
            title: '清除阅读存档',
            subtitle: '已记录 $_readPosCount 个续读点',
            destructive: true,
            onTap: _readPosCount == 0 ? null : _clearReadPositions,
          ),
          const Divider(height: 18),
          SwitchListTile(
            value: settings.askResumeOnSearch,
            onChanged: (v) => settings.setAskResumeOnSearch(v),
            title: Text('搜索时提示续读',
                style: TextStyle(fontSize: 14, color: AppTheme.inkPrimary)),
            subtitle: Text(
              '命中续读点时询问是否接着上次的位置读',
              style: TextStyle(fontSize: 12, color: AppTheme.inkTertiary),
            ),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
          SwitchListTile(
            value: settings.showReadMarkers,
            onChanged: (v) => settings.setShowReadMarkers(v),
            title: Text('标记已读内容',
                style: TextStyle(fontSize: 14, color: AppTheme.inkPrimary)),
            subtitle: Text(
              '列表里给完整读过的条目加上「已读」标识',
              style: TextStyle(fontSize: 12, color: AppTheme.inkTertiary),
            ),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- 数据备份

  /// 数据备份：把本机全部数据导出成一个 JSON 文件 / 从备份文件恢复。
  ///
  /// 备份是平台无关的 JSON（见 `BackupService`），可用于换机、换包名版本的
  /// 迁移，也为将来的网页版互通预留了格式。**不含访问凭证**。
  Widget _backupCard() {
    final busy = _backupBusy;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle('数据备份'),
          const SizedBox(height: 6),
          Text(
            '把本机全部数据（设置、搜索历史、续读点、收藏的合集、已缓存的内容、'
            '点赞记录、用户备注）导出为一个 JSON 文件；换机或重装后导入即可恢复。'
            '文件落在「下载/Simple阅读」里，用系统「文件」或数据线都能取走。'
            '备份不含访问凭证，导入后如需换账号请重新登录。'
            '导入也可以只恢复其中一部分：文件里没有的类别不会改动本机数据。',
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.inkTertiary,
              height: 1.55,
            ),
          ),
          const SizedBox(height: 6),
          _actionRow(
            icon: Icons.upload_file_outlined,
            title: '导出数据',
            subtitle: _lastExportPath ?? '生成备份文件（下载/Simple阅读）',
            trailing: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: busy ? null : _exportData,
          ),
          const Divider(height: 18),
          _actionRow(
            icon: Icons.download_for_offline_outlined,
            title: '导入数据',
            subtitle: '选择备份文件恢复本机数据（覆盖同类数据）',
            onTap: busy ? null : _importData,
          ),
        ],
      ),
    );
  }

  Future<void> _exportData() async {
    setState(() => _backupBusy = true);
    String? path;
    String? failure;
    var bytes = 0;
    try {
      final text = await BackupService.exportText();
      bytes = text.length;
      path = await NativeBridge.instance.exportBackup(
        BackupService.defaultFileName(),
        text,
      );
    } catch (e) {
      failure = '$e';
    }
    if (!mounted) return;
    setState(() {
      _backupBusy = false;
      _lastExportPath = path == null ? '导出失败' : '上次导出：$path';
    });
    if (path == null) {
      _toast('导出失败${failure == null ? '' : '：$failure'}');
    } else {
      _toast('已导出 ${(bytes / 1024).toStringAsFixed(0)} KB 到 $path');
    }
  }

  Future<void> _importData() async {
    final file = await NativeBridge.instance.importBackup();
    if (!mounted || file == null) return; // 用户取消

    final payload = BackupService.parse(file.content);
    if (payload == null) {
      _toast('这不是本应用导出的备份，或版本不兼容');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入数据', style: TextStyle(fontSize: 17)),
        content: Text(
          '备份文件：${file.name}\n'
          '导出于：${formatDateTime(payload.exportedAt)}'
          '${payload.appVersion.isEmpty ? '' : '（v${payload.appVersion}）'}\n\n'
          '文件包含：'
          '${payload.includedLabels.isEmpty ? '（没有可识别的类别）' : payload.includedLabels.join('、')}\n'
          '其中的数量：已缓存内容 ${payload.cacheEntryCount} 页、'
          '收藏的合集 ${payload.collectionCount} 个、'
          '搜索历史 ${payload.historyCount} 条、'
          '续读点 ${payload.readPositionCount} 个、'
          '用户备注 ${payload.remarkCount} 条。\n\n'
          '导入会覆盖文件里列出的类别，本机这些数据不可恢复；'
          '文件里没有的类别保持原样。'
          '访问凭证不在备份里，需要重新登录。',
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('覆盖导入'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _backupBusy = true);
    BackupImportSummary? summary;
    String? failure;
    try {
      summary = await BackupService.apply(payload);
    } catch (e) {
      failure = '$e';
    }
    if (!mounted) return;
    setState(() => _backupBusy = false);
    await _refreshStats();
    if (!mounted) return;
    if (summary == null) {
      _toast('导入失败${failure == null ? '' : '：$failure'}');
      return;
    }
    _toast(
      '导入完成：缓存 ${summary.cacheEntries} 页、'
      '合集 ${summary.collections} 个、历史 ${summary.historyItems} 条、'
      '续读点 ${summary.readPositions} 个、备注 ${summary.remarks} 条'
      '（界面已刷新）',
    );
  }

  // ---------------------------------------------------------------- 操作

  /// 凭证与链接相关操作。「切换到网页版」按需求留在「我的」页，不在此列。
  Widget _actionsCard(AppState app) {
    final settings = AppSettings.instance;
    return _card(
      child: Column(
        children: [
          _actionRow(
            icon: Icons.new_releases_outlined,
            title: '更新内容',
            subtitle: '看看各个版本改了什么（启动时的提示看漏了可以在这补）',
            onTap: () => showUpdateNotesDialog(context, showAll: true),
          ),
          const Divider(height: 18),
          _actionRow(
            icon: Icons.school_outlined,
            title: '功能导览',
            subtitle: '再看一次功能速览（订阅合集、解析合集、缓存与续读）',
            onTap: () => showFeatureTour(context),
          ),
          const Divider(height: 18),
          _actionRow(
            icon: Icons.refresh_rounded,
            title: '重新校验凭证',
            subtitle: '向服务端确认当前 token 是否仍然有效',
            trailing: _busy
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _busy || !app.hasToken ? null : _revalidate,
          ),
          const Divider(height: 18),
          _actionRow(
            icon: Icons.swap_horiz_rounded,
            title: '更换 Token',
            subtitle: '粘贴新的 token 覆盖本机保存的值',
            onTap: _replaceToken,
          ),
          const Divider(height: 18),
          _actionRow(
            icon: Icons.delete_outline_rounded,
            title: '清除本机凭证',
            subtitle: '从本机删除已保存的 token',
            destructive: true,
            onTap: app.hasToken ? _logout : null,
          ),
          const Divider(height: 18),
          SwitchListTile(
            value: settings.openLinksInApp,
            onChanged: (v) => settings.setOpenLinksInApp(v),
            title: Text('正文链接在应用内打开',
                style: TextStyle(fontSize: 14, color: AppTheme.inkPrimary)),
            subtitle: Text(
              '关闭后正文与分享链接改用系统浏览器',
              style: TextStyle(fontSize: 12, color: AppTheme.inkTertiary),
            ),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
          const Divider(height: 18),
          SwitchListTile(
            value: settings.interactionButtonsOnRight,
            onChanged: (v) => settings.setInteractionButtonsOnRight(v),
            title: Text('互动按钮右置',
                style: TextStyle(fontSize: 14, color: AppTheme.inkPrimary)),
            subtitle: Text(
              '列表里的点赞/评论/收藏放在右侧，展开全文与折叠放到左侧；'
              '关闭则两者左右对调',
              style: TextStyle(fontSize: 12, color: AppTheme.inkTertiary),
            ),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 关于

  Widget _aboutCard() {
    // 「关于」内容与首次登录后的提示页共用同一份（见 AboutContent），
    // 避免两处说法不一致。
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle('关于'),
          const SizedBox(height: 10),
          const AboutContent(),
        ],
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
}
