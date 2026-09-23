import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../util/app_log.dart';
import 'theme.dart';
import 'widgets/brightness_aware.dart';

/// 「运行日志」页 —— 应用内的 logcat。
///
/// 目标是在**不接电脑、不装 adb** 的前提下把排查所需的信息完整看到：
/// * 按级别 / 分类筛选，按关键词搜索；
/// * 每条日志带毫秒级时间戳，可按行复制；
/// * 一键复制筛选结果，便于贴出来定位问题；
/// * 日志同时落盘（应用私有目录 logs/run.log），重启后仍能回看上一次现场；
/// * 可选把调试级日志镜像到 stdout，`adb logcat` 里同步可见。
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  /// null = 全部级别。
  LogLevel? _minLevel;

  /// null = 全部分类。
  LogTag? _tag;

  final TextEditingController _query = TextEditingController();

  int _fileBytes = -1;

  @override
  void initState() {
    super.initState();
    _refreshSize();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _refreshSize() async {
    final n = await log.fileSize();
    if (!mounted) return;
    setState(() => _fileBytes = n);
  }

  List<LogEntry> get _filtered {
    final q = _query.text.trim().toLowerCase();
    return [
      for (final e in log.entries)
        if ((_minLevel == null || e.level.index >= _minLevel!.index) &&
            (_tag == null || e.tag == _tag) &&
            (q.isEmpty ||
                e.message.toLowerCase().contains(q) ||
                e.tag.key.contains(q)))
          e,
    ];
  }

  Future<void> _copy({required bool onlyFiltered}) async {
    final lines = onlyFiltered
        ? [for (final e in _filtered) e.fileLine]
        : log.toLines();
    if (lines.isEmpty) {
      _toast('没有可复制的内容');
      return;
    }
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    _toast('已复制 ${lines.length} 行日志');
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空运行日志', style: TextStyle(fontSize: 17)),
        content: const Text(
          '将清空内存里与磁盘上的全部日志。清空后无法恢复。',
          style: TextStyle(fontSize: 13.5, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await log.clear();
    await _refreshSize();
    if (mounted) _toast('日志已清空');
  }

  void _toast(String msg) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  String get _sizeText {
    if (_fileBytes < 0) return '读取中…';
    if (_fileBytes < 1024) return '$_fileBytes B';
    return '${(_fileBytes / 1024).toStringAsFixed(1)} KB';
  }

  @override
  Widget build(BuildContext context) {
    // 包一层亮度依赖：本页配色全是静态语义色，不重建就会停在旧主题。
    return BrightnessAware(builder: (context, _) => _contents());
  }

  Widget _contents() {
    return Scaffold(
      backgroundColor: AppTheme.pageBackground,
      appBar: AppBar(
        title: const Text('运行日志'),
        actions: [
          IconButton(
            tooltip: '复制筛选结果',
            onPressed: () => _copy(onlyFiltered: true),
            icon: const Icon(Icons.copy_all_rounded, size: 19),
          ),
          IconButton(
            tooltip: '清空日志',
            onPressed: _clear,
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: log,
        builder: (context, _) => Column(
          children: [
            _toolbar(),
            Expanded(child: _list()),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 控制条

  Widget _toolbar() {
    final filtered = _filtered;
    return Container(
      color: AppTheme.cardBackground,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        children: [
          Row(
            children: [
              _levelChip('全部', null),
              const SizedBox(width: 6),
              _levelChip('信息+', LogLevel.info),
              const SizedBox(width: 6),
              _levelChip('警告+', LogLevel.warn),
              const SizedBox(width: 6),
              _levelChip('仅错误', LogLevel.error),
              const Spacer(),
              Text(
                '${filtered.length}/${log.length} 行',
                style: TextStyle(
                  fontSize: 11.5,
                  color: AppTheme.inkTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          SizedBox(
            height: 28,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _tagChip('全部', null),
                for (final t in LogTag.values) ...[
                  const SizedBox(width: 6),
                  _tagChip(t.label, t),
                ],
              ],
            ),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: TextField(
                    controller: _query,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: '按关键词过滤（如 跳页、cache、401）',
                      hintStyle: TextStyle(
                          fontSize: 12.5, color: AppTheme.inkTertiary),
                      prefixIcon: Icon(Icons.filter_alt_outlined,
                          size: 16, color: AppTheme.inkTertiary),
                      prefixIconConstraints:
                          const BoxConstraints(minWidth: 34, minHeight: 34),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      isDense: true,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.sd_storage_outlined,
                  size: 13, color: AppTheme.inkTertiary),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '磁盘日志 $_sizeText · 最新在上'
                  '${log.dropped > 0 ? ' · 内存已丢弃 ${log.dropped} 行' : ''}',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.inkTertiary,
                  ),
                ),
              ),
              Text(
                '同步到系统日志',
                style: TextStyle(
                  fontSize: 11,
                  color: log.mirrorDebug
                      ? AppTheme.accent
                      : AppTheme.inkTertiary,
                ),
              ),
              SizedBox(
                height: 26,
                child: Switch(
                  value: log.mirrorDebug,
                  onChanged: (v) {
                    log.mirrorDebug = v;
                    setState(() {});
                    _toast(v ? '调试级日志将写入系统日志（logcat）' : '只把信息级以上写系统日志');
                  },
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _levelChip(String label, LogLevel? level) {
    final on = _minLevel == level;
    return InkWell(
      onTap: () => setState(() => _minLevel = level),
      borderRadius: BorderRadius.circular(7),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: on ? AppTheme.accent : AppTheme.surfaceMuted,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: on ? Colors.white : AppTheme.inkSecondary,
            fontWeight: on ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _tagChip(String label, LogTag? tag) {
    final on = _tag == tag;
    return InkWell(
      onTap: () => setState(() => _tag = tag),
      borderRadius: BorderRadius.circular(7),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: on ? AppTheme.accent : AppTheme.surfaceMuted,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: on ? Colors.white : AppTheme.inkSecondary,
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 列表

  Widget _list() {
    final items = _filtered;
    if (items.isEmpty) {
      return Center(
        child: Text(
          '没有符合条件的日志',
          style: TextStyle(fontSize: 13, color: AppTheme.inkTertiary),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 24),
      itemCount: items.length,
      itemBuilder: (context, i) => _entry(items[i]),
    );
  }

  Widget _entry(LogEntry e) {
    final color = switch (e.level) {
      LogLevel.error => AppTheme.danger,
      LogLevel.warn => AppTheme.warning,
      LogLevel.info => AppTheme.inkPrimary,
      LogLevel.debug => AppTheme.inkTertiary,
    };
    return InkWell(
      onLongPress: () async {
        await Clipboard.setData(ClipboardData(text: e.fileLine));
        _toast('已复制该行');
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        decoration: BoxDecoration(
          color: AppTheme.cardBackground,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: AppTheme.divider, width: 0.6),
        ),
        child: Text(
          e.fileLine,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.5,
            fontFamily: 'monospace',
            color: color,
          ),
        ),
      ),
    );
  }
}

/// 把日志里的 [LogEntry.line] 渲染成带级别的颜色，供需要时复用。
Color logLevelColor(LogLevel level) => switch (level) {
      LogLevel.error => AppTheme.danger,
      LogLevel.warn => AppTheme.warning,
      LogLevel.info => AppTheme.inkPrimary,
      LogLevel.debug => AppTheme.inkTertiary,
    };
