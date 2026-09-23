/// 纯文本里的超链接识别。
///
/// 服务端把正文中的 URL 交给前端渲染成卡片，客户端不做卡片还原，
/// 只保证「链接可见、可点、用默认浏览器打开」。
library;

/// 文本中一处链接的位置与地址。
class TextLink {
  const TextLink({
    required this.start,
    required this.end,
    required this.url,
  });

  /// 在原文中的起始（含）与结束（不含）下标。
  final int start;
  final int end;

  /// 去掉尾部标点后的可用地址。
  final String url;

  /// 原文中的显示片段（可能含尾部标点）。
  String displayOf(String source) => source.substring(start, end);
}

/// 匹配 `http(s)://…`。排除空白与常见的中英文包裹符号，
/// 避免把「（见 https://a.com）」里的右括号吞进地址。
final RegExp _urlPattern = RegExp(
  r'https?://[^\s\u3000<>"' r"'" r'“”‘’「」『』【】〈〉（）()\[\]{}，。；：！？、]+',
  caseSensitive: false,
);

/// 会出现在链接尾部、但不属于地址本身的标点。
const String _trailingPunctuation = '.,;:!?、。，；：！？…·-—\'"”“’‘';

/// 找出文本中所有链接。
List<TextLink> findTextLinks(String text) {
  if (text.isEmpty || !text.contains('http')) return const [];

  final out = <TextLink>[];
  for (final m in _urlPattern.allMatches(text)) {
    final raw = m.group(0)!;
    final url = _trimTrailing(raw);
    if (url.isEmpty || !isHttpUrl(url)) continue;
    out.add(TextLink(
      start: m.start,
      // 尾部标点留在正文里，不划入链接范围。
      end: m.start + url.length,
      url: url,
    ));
  }
  return out;
}

/// 文本里第一个链接的地址，没有则返回 null。
String? firstTextLink(String text) {
  final links = findTextLinks(text);
  return links.isEmpty ? null : links.first.url;
}

/// 是否是可直接打开的 http(s) 地址。
bool isHttpUrl(String s) {
  final v = s.trim().toLowerCase();
  if (!v.startsWith('http://') && !v.startsWith('https://')) return false;
  // 至少要有一个像样的主机名。
  final rest = v.substring(v.indexOf('://') + 3);
  if (rest.isEmpty) return false;
  final host = rest.split('/').first;
  return host.isNotEmpty && !host.startsWith(':');
}

String _trimTrailing(String raw) {
  var s = raw;
  while (s.isNotEmpty) {
    final last = s[s.length - 1];
    if (_trailingPunctuation.contains(last)) {
      s = s.substring(0, s.length - 1);
    } else {
      break;
    }
  }
  return s;
}

/// 链接在界面上展示用的短文本：过长时保留域名与头部，尾部省略。
String shortenUrl(String url, {int max = 48}) {
  if (url.length <= max) return url;
  final cut = url.substring(0, max);
  return '$cut…';
}

/// 取域名，用于链接卡片风格的展示。
String hostOf(String url) {
  try {
    final uri = Uri.parse(url);
    if (uri.host.isNotEmpty) return uri.host;
  } catch (_) {
    // 忽略：交给下面的兜底。
  }
  final s = url.indexOf('://');
  final rest = s >= 0 ? url.substring(s + 3) : url;
  return rest.split('/').first;
}
