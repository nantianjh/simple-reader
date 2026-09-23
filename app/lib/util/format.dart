/// 时间展示工具。
///
/// 手写而不引入 intl：只需要中文相对时间与固定格式两种形态，
/// 引入完整 i18n 依赖不划算。
library;

String two(int n) => n.toString().padLeft(2, '0');

/// 相对时间。超过 30 天退化为绝对日期。
String timeAgo(DateTime? dt) {
  if (dt == null) return '';
  final local = dt.toLocal();
  final now = DateTime.now();
  final diff = now.difference(local);

  if (diff.isNegative) return formatDateTime(local);
  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}

/// 绝对时间：`2026-09-13 20:15`。
String formatDateTime(DateTime? dt) {
  if (dt == null) return '';
  final l = dt.toLocal();
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

/// 相对剩余时长，用于 token 有效期提示。
String humanDuration(Duration d) {
  if (d.isNegative) return '已过期';
  if (d.inDays >= 1) {
    final hours = d.inHours % 24;
    return hours > 0 ? '${d.inDays} 天 ${hours} 小时' : '${d.inDays} 天';
  }
  if (d.inHours >= 1) {
    final minutes = d.inMinutes % 60;
    return minutes > 0 ? '${d.inHours} 小时 ${minutes} 分' : '${d.inHours} 小时';
  }
  if (d.inMinutes >= 1) return '${d.inMinutes} 分';
  return '不足 1 分钟';
}

/// 大数字压缩：12345 -> 1.2万。
String compactCount(int n) {
  if (n < 1000) return '$n';
  if (n < 10000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '${(n / 10000).toStringAsFixed(1)}万';
}
