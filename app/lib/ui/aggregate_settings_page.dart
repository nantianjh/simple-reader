import 'package:flutter/material.dart';

import '../data/search_history.dart';
import '../data/settings.dart';
import 'theme.dart';
import 'widgets/brightness_aware.dart';

/// 「综合阅读」设置页：从搜索历史里挑哪些关键词参与综合阅读。
///
/// 这是「我的」一级页的独立入口（用户 2026-10-09 需求 3）。词单来源=
/// 搜索历史；这里只做勾选管理，不新建词（新词请去搜索页搜一次）。
class AggregateSettingsPage extends StatefulWidget {
  const AggregateSettingsPage({super.key});

  @override
  State<AggregateSettingsPage> createState() => _AggregateSettingsPageState();
}

class _AggregateSettingsPageState extends State<AggregateSettingsPage> {
  /// 候选词 = 搜索历史（MRU 顺序）+ 已选中但已不在历史里的词（追加在后）。
  ///
  /// 后者保留展示而不是自动剔除：用户清空/删除搜索历史时，不该连带
  /// 悄悄丢掉精心挑过的综合阅读词单；要不要移除由用户在这里决定。
  List<String> get _candidates {
    final out = <String>[...SearchHistory.instance.items];
    for (final k in AppSettings.instance.aggregateKeywords) {
      if (!out.contains(k)) out.add(k);
    }
    return out;
  }

  bool _selected(String k) =>
      AppSettings.instance.aggregateKeywords.contains(k);

  Future<void> _setSelected(String k, bool on) async {
    final cur = List<String>.of(AppSettings.instance.aggregateKeywords);
    if (on) {
      if (!cur.contains(k)) cur.add(k);
    } else {
      cur.remove(k);
    }
    await AppSettings.instance.setAggregateKeywords(cur);
    if (mounted) setState(() {});
  }

  Future<void> _setAll(List<String> all, bool on) async {
    await AppSettings.instance
        .setAggregateKeywords(on ? List<String>.of(all) : <String>[]);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return BrightnessAware(builder: (context, _) => _contents());
  }

  Widget _contents() {
    final candidates = _candidates;
    final selected = AppSettings.instance.aggregateKeywords.length;

    return Scaffold(
      backgroundColor: AppTheme.pageBackground,
      appBar: AppBar(title: const Text('综合阅读')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: [
          _introCard(),
          const SizedBox(height: 14),
          _keywordsCard(candidates, selected),
        ],
      ),
    );
  }

  Widget _introCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle('综合阅读'),
          const SizedBox(height: 8),
          Text(
            '把选中的搜索词各自的最新内容合并成一条列表，按发布时间从新到旧'
            '排列，不标注每条内容来自哪个词。',
            style: TextStyle(
              fontSize: 12.5,
              color: AppTheme.inkSecondary,
              height: 1.7,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '打开「综合阅读」时优先读本地缓存（秒开），点右上角刷新才会联网；'
            '联网重抓时会自动往下抓，直到每个词都接上你上次看过的位置就停；'
            '想继续看更早的内容，往下滑到底会接着抓。',
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.inkTertiary,
              height: 1.7,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '词单来自你的搜索历史；新词先在搜索页搜一次，再回这里挑选。',
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.inkTertiary,
              height: 1.7,
            ),
          ),
        ],
      ),
    );
  }

  Widget _keywordsCard(List<String> candidates, int selected) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _cardTitle('关键词'),
              const SizedBox(width: 8),
              Text(
                candidates.isEmpty
                    ? ''
                    : '已选 $selected/${candidates.length}',
                style: TextStyle(fontSize: 12, color: AppTheme.inkTertiary),
              ),
              const Spacer(),
              if (candidates.isNotEmpty) ...[
                TextButton(
                  onPressed: () => _setAll(candidates, true),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('全选', style: TextStyle(fontSize: 12.5)),
                ),
                TextButton(
                  onPressed: () => _setAll(candidates, false),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: AppTheme.inkTertiary,
                  ),
                  child: const Text('全不选', style: TextStyle(fontSize: 12.5)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          if (candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  '搜索历史里还没有关键词\n先去搜索页搜几个词，再回来挑选',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.inkTertiary,
                    height: 1.8,
                  ),
                ),
              ),
            )
          else
            for (final k in candidates) _keywordRow(k),
        ],
      ),
    );
  }

  Widget _keywordRow(String keyword) {
    final inHistory = SearchHistory.instance.items.contains(keyword);
    return SwitchListTile(
      value: _selected(keyword),
      onChanged: (v) => _setSelected(keyword, v),
      title: Text(
        keyword,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 14, color: AppTheme.inkPrimary),
      ),
      subtitle: inHistory
          ? null
          : Text(
              '已不在搜索历史中',
              style: TextStyle(fontSize: 11.5, color: AppTheme.inkTertiary),
            ),
      contentPadding: EdgeInsets.zero,
      dense: true,
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }

  Widget _cardTitle(String t) => Text(
        t,
        style: TextStyle(
          fontSize: 14.5,
          fontWeight: FontWeight.w600,
          color: AppTheme.inkPrimary,
        ),
      );
}
