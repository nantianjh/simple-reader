import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../state/app_scope.dart';
import '../../state/emoji_cache.dart';
import '../../util/app_log.dart';
import '../theme.dart';
import 'net_image.dart';

/// 评论输入框上方的表情面板。
///
/// 数据全部经 [EmojiCache] 全局缓存（v1.9.2）：内存命中直接渲染（0 请求），
/// 磁盘快照保证冷启动秒开，超过 TTL 才真正发请求刷新。此前面板每次展开
/// 都重建 State 并重拉全部数据，表现为"每次点开都要加载一圈"。
///
/// 数据本身（均为账号级，《四需求可行性-探查报告.md》第五节实测）：
/// * 「收藏」= `GET api/v2/emojis/favorites` —— 当前登录用户的表情；
/// * 系统包 = `GET api/v2/emojis/packages`，包内容
///   `GET api/v2/emojis?package_emoji_id=` 按需加载（该参数必填，
///   缺参服务端直接 400）。
///
/// **点选表情不往输入框插文本**：评论里的表情是作为 media 图片项
/// （`{type:"image", url}`）随评论一起发送的，这里只负责挑选并把
/// 结果回调给输入栏；已选中的表情显示角标，再次点选即取消。
class EmojiPanel extends StatefulWidget {
  const EmojiPanel({
    super.key,
    required this.onPick,
    required this.pickedIds,
  });

  /// 点选某个表情（已选中时由父级判断为取消）。
  final void Function(Emoji emoji) onPick;

  /// 当前已挑选的表情 id 集合（显示角标用）。
  final Set<String> pickedIds;

  @override
  State<EmojiPanel> createState() => _EmojiPanelState();
}

class _EmojiPanelState extends State<EmojiPanel> {
  /// tab 顺序：收藏（账号表情）→ 各系统包。
  final List<EmojiPackage> _packages = [];
  bool _packagesLoading = true;
  String? _packagesError;

  /// 本实例已就绪的 tab 内容（引用 [EmojiCache] 的共享列表，只读）。
  final Map<String, List<Emoji>> _loaded = {};
  final Set<String> _loadingKeys = {};
  final Map<String, String> _keyErrors = {};

  int _current = 0;

  String get _currentKey => _current == 0 ? 'fav' : _packages[_current - 1].id;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    final token = AppScope.read(context).token;
    if (token == null || token.isEmpty) {
      setState(() {
        _packagesLoading = false;
        _packagesError = '未配置 token，表情面板不可用';
      });
      return;
    }
    // 先把已有缓存（内存或磁盘快照）画出来——命中时这一步就是最终状态，
    // 网格立即出现，不再有"加载一圈"的空窗。
    final cached = EmojiCache.instance.packages;
    if (cached != null && mounted) {
      setState(() {
        _packages
          ..clear()
          ..addAll(cached);
        _packagesLoading = false;
      });
    }
    try {
      final pkgs = await EmojiCache.instance.ensureBase(token: token);
      if (!mounted) return;
      setState(() {
        _packages
          ..clear()
          ..addAll(pkgs);
        _packagesLoading = false;
        _packagesError = null;
      });
      await _ensureTabContent('fav');
    } catch (e) {
      log.w(LogTag.net, '表情包列表加载失败：$e');
      if (!mounted) return;
      setState(() {
        _packagesLoading = false;
        // 已渲染出旧缓存（哪怕是过期快照）就继续用，不打断使用；
        // 完全没有数据才进入"点击重试"。
        if (_packages.isEmpty) _packagesError = '表情加载失败，点击重试';
      });
    }
  }

  /// 确保当前 tab 的内容已加载（收藏 / 各系统包按需拉取）。
  Future<void> _ensureCurrentTab() async {
    final key = _currentKey;
    if (_loaded.containsKey(key) || _loadingKeys.contains(key)) return;
    await _ensureTabContent(key);
  }

  Future<void> _ensureTabContent(String key) async {
    final token = AppScope.read(context).token;
    if (token == null || token.isEmpty) return;

    // 缓存命中（含磁盘快照）：直接渲染，不发请求。
    final cached = EmojiCache.instance.contentOf(key);
    if (cached != null && mounted) {
      setState(() {
        _loaded[key] = cached;
        _keyErrors.remove(key);
      });
      return;
    }
    if (_loadingKeys.contains(key)) return;

    setState(() => _loadingKeys.add(key));
    try {
      final emojis = await EmojiCache.instance.ensureContent(
        key,
        token: token,
      );
      if (!mounted) return;
      setState(() {
        _loaded[key] = emojis;
        _keyErrors.remove(key);
      });
    } catch (e) {
      log.w(LogTag.net, '表情内容加载失败（$key）：$e');
      if (!mounted) return;
      setState(() => _keyErrors[key] = '加载失败，点击重试');
    } finally {
      if (mounted) setState(() => _loadingKeys.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _tabs(),
        Divider(height: 0.6, color: AppTheme.divider),
        Expanded(child: _grid()),
      ],
    );
  }

  // ------------------------------------------------------------------ tabs

  Widget _tabs() {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        children: [
          _tab(
            index: 0,
            label: '收藏',
            icon: Icons.star_rounded,
            selected: _current == 0,
          ),
          for (var i = 0; i < _packages.length; i++)
            _tab(
              index: i + 1,
              label: _packages[i].name,
              iconUrl: _packages[i].icon,
              selected: _current == i + 1,
            ),
        ],
      ),
    );
  }

  Widget _tab({
    required int index,
    required String label,
    IconData? icon,
    String? iconUrl,
    required bool selected,
  }) {
    final color = selected ? AppTheme.accent : AppTheme.inkTertiary;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: () {
          setState(() => _current = index);
          _ensureCurrentTab();
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.accent.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? AppTheme.accent.withValues(alpha: 0.35)
                  : Colors.transparent,
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null)
                Icon(icon, size: 15, color: color)
              else if (iconUrl != null && iconUrl.isNotEmpty)
                NetImage(url: iconUrl, width: 15, height: 15)
              else
                Icon(Icons.image_outlined, size: 15, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: color,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ grid

  Widget _grid() {
    if (_packagesLoading) {
      return const Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 1.8),
        ),
      );
    }
    if (_packagesError != null) {
      return GestureDetector(
        onTap: () {
          setState(() => _packagesError = null);
          _loadAll();
        },
        child: Center(
          child: Text(
            _packagesError!,
            style: TextStyle(fontSize: 12.5, color: AppTheme.inkTertiary),
          ),
        ),
      );
    }

    final key = _currentKey;
    if (_loadingKeys.contains(key)) {
      return const Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 1.8),
        ),
      );
    }
    final err = _keyErrors[key];
    if (err != null) {
      return GestureDetector(
        onTap: _ensureCurrentTab,
        child: Center(
          child: Text(
            err,
            style: TextStyle(fontSize: 12.5, color: AppTheme.inkTertiary),
          ),
        ),
      );
    }
    final emojis = _loaded[key] ?? const <Emoji>[];
    if (emojis.isEmpty) {
      return Center(
        child: Text(
          key == 'fav' ? '还没有收藏过表情' : '这个包暂时没有内容',
          style: TextStyle(fontSize: 12.5, color: AppTheme.inkTertiary),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 64,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: emojis.length,
      itemBuilder: (context, i) => _emojiCell(emojis[i]),
    );
  }

  Widget _emojiCell(Emoji e) {
    final picked = widget.pickedIds.contains(e.id);
    return InkWell(
      onTap: () => widget.onPick(e),
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          Positioned.fill(
            child: NetImage(
              url: e.thumbUrl,
              fit: BoxFit.contain,
              errorIcon: Icons.emoji_emotions_outlined,
            ),
          ),
          if (picked)
            Positioned(
              right: 0,
              top: 0,
              child: Container(
                padding: const EdgeInsets.all(1),
                decoration: BoxDecoration(
                  color: AppTheme.accent,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_rounded,
                    size: 10, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}
