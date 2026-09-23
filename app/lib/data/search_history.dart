import 'local_store.dart';

/// 搜索历史。
///
/// 最近使用优先（MRU）：重复的关键词上移而不新增，
/// 超出上限时裁掉最旧的一条。
class SearchHistory {
  SearchHistory._();

  static final SearchHistory instance = SearchHistory._();

  /// 最多保留的历史条目数。
  static const int maxEntries = 30;

  final List<String> _items = [];

  List<String> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;
  int get length => _items.length;

  Future<void> load() async {
    _items.clear();
    for (final v in LocalStore.instance.readList(LocalStore.keySearchHistory)) {
      final s = v.toString().trim();
      if (s.isEmpty) continue;
      if (_items.contains(s)) continue;
      _items.add(s);
      if (_items.length >= maxEntries) break;
    }
  }

  /// 记录一次搜索。
  Future<void> add(String keyword) async {
    final k = keyword.trim();
    if (k.isEmpty) return;
    _items.remove(k);
    _items.insert(0, k);
    while (_items.length > maxEntries) {
      _items.removeLast();
    }
    await _persist();
  }

  Future<void> remove(String keyword) async {
    if (!_items.remove(keyword)) return;
    await _persist();
  }

  Future<void> clear() async {
    if (_items.isEmpty) return;
    _items.clear();
    await _persist();
  }

  Future<void> _persist() =>
      LocalStore.instance.write(LocalStore.keySearchHistory, _items);
}
