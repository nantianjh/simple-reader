import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../platform/native_bridge.dart';

/// 日志级别。取值与 logcat 的 V/D/I/W/E 对齐，便于对照。
enum LogLevel {
  debug('D', '调试'),
  info('I', '信息'),
  warn('W', '警告'),
  error('E', '错误');

  const LogLevel(this.letter, this.label);

  final String letter;
  final String label;
}

/// 日志分类（相当于 logcat 的 tag）。
///
/// 分类是硬编码的枚举而不是自由字符串：界面上要按分类筛选，
/// 自由字符串会让筛选条失控（拼错一个字母就多出一个空分类）。
enum LogTag {
  app('app', '应用'),
  net('net', '网络'),
  cache('cache', '缓存'),
  page('page', '翻页'),
  read('read', '续读'),
  auth('auth', '凭证'),
  fav('fav', '收藏'),
  ui('ui', '交互');

  const LogTag(this.key, this.label);

  final String key;
  final String label;

  static LogTag fromKey(String k) {
    for (final v in LogTag.values) {
      if (v.key == k) return v;
    }
    return LogTag.app;
  }
}

/// 一条日志。
class LogEntry {
  const LogEntry({
    required this.seq,
    required this.at,
    required this.level,
    required this.tag,
    required this.message,
  });

  /// 自增序号，用于打不开时间戳时的稳定排序。
  final int seq;
  final DateTime at;
  final LogLevel level;
  final LogTag tag;
  final String message;

  String get time {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}:${two(at.second)}'
        '.${three(at.millisecond)}';
  }

  /// 时钟部分（不含日期），供 [fileLine] 复用。
  String get _clock {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}'
        '.${three(at.millisecond)}';
  }

  String get line => '$time ${level.letter} ${tag.key}  $message';

  /// 落盘 / 复制用的整行，日期用完整年份（跨天、跨次启动后仍可读）。
  String get fileLine {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} $_clock'
        ' ${level.letter} ${tag.key}  $message';
  }
}

/// 应用内运行日志（等效于 logcat 的客户端实现）。
///
/// 三件能力：
/// 1. **内存环形缓冲**：最新 [maxEntries] 条随时可取，界面直接渲染；
/// 2. **落盘**：通过原生 `logs` 通道追加到应用私有目录的文件里，
///    应用重启或进程崩溃后仍能看到上一次的记录，文件自动限制大小；
/// 3. **镜像到 stdout**：`print` 在 Android 上会进入 logcat（tag `flutter`），
///    因此 `adb logcat` 也能看到同一份内容，便于与设备日志对照。
///
/// 设计约束沿用工程约定：零第三方依赖、异常全部吞并（日志系统自身出问题
/// 绝不能影响主流程），因此所有原生调用都做了降级。
class AppLog extends ChangeNotifier {
  AppLog._();

  static final AppLog instance = AppLog._();

  /// 内存里保留的最大条数。
  static const int maxEntries = 1200;

  /// 启动时从文件回读的最大行数。
  static const int _restoreLines = 800;

  /// 低于该级别的日志只留在内存里，不镜像到 logcat。
  ///
  /// 调试级日志量大且噪音多，正式包里默认不进 stdout；
  /// 在「运行日志」页打开「同步到系统日志」后全部镜像。
  LogLevel _stdoutFloor = LogLevel.info;

  /// 是否已经至少加载过一次磁盘缓冲。
  bool _restored = false;

  final List<LogEntry> _entries = <LogEntry>[];

  final List<String> _pending = <String>[];

  Timer? _flushTimer;

  int _seq = 0;
  int _dropped = 0;

  bool get restored => _restored;

  /// 因超出容量被丢弃的历史条数。
  int get dropped => _dropped;

  int get length => _entries.length;

  LogLevel get stdoutFloor => _stdoutFloor;

  /// 是否把调试级日志也镜像到 stdout（logcat）。
  bool get mirrorDebug => _stdoutFloor == LogLevel.debug;

  set mirrorDebug(bool v) {
    _stdoutFloor = v ? LogLevel.debug : LogLevel.info;
    notifyListeners();
  }

  /// 全部条目的只读快照，**最新的在最前**（界面直接渲染，无需倒序）。
  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries.reversed);

  // ------------------------------------------------------------------ 写入

  void d(LogTag tag, String message) => add(LogLevel.debug, tag, message);

  void i(LogTag tag, String message) => add(LogLevel.info, tag, message);

  void w(LogTag tag, String message) => add(LogLevel.warn, tag, message);

  void e(LogTag tag, String message) => add(LogLevel.error, tag, message);

  /// 记录一条日志。[message] 支持多行，落盘时按行拆分。
  void add(LogLevel level, LogTag tag, Object? message) {
    final text = message?.toString() ?? '';
    final e = LogEntry(
      seq: ++_seq,
      at: DateTime.now(),
      level: level,
      tag: tag,
      message: text,
    );

    _entries.add(e);
    if (_entries.length > maxEntries) {
      final over = _entries.length - maxEntries;
      _entries.removeRange(0, over);
      _dropped += over;
    }

    if (level.index >= _stdoutFloor.index) {
      // 在 Android 上 print 会进入 logcat；这里不做 debugPrint 的节流，
      // 因为日志量已由调用点控制，且节流会丢时间敏感的顺序信息。
      // ignore: avoid_print
      print(e.fileLine);
    }

    _pending.add(e.fileLine);
    _scheduleFlush();

    notifyListeners();
  }

  /// 记录异常（自动展开栈）。
  void exception(LogTag tag, String what, Object error, [StackTrace? stack]) {
    final buf = StringBuffer('$what：${_describe(error)}');
    if (stack != null) {
      final lines = stack.toString().split('\n');
      for (final l in lines.take(12)) {
        buf.write('\n    $l');
      }
    }
    add(LogLevel.error, tag, buf.toString());
  }

  /// 计时段辅助：`final sw = AppLog.stopwatch(); ... sw('耗时说明')`。
  Stopwatch stopwatch() => Stopwatch()..start();

  /// 给一段耗时生成 `(123 ms)` 后缀，便于拼进日志文本。
  static String ms(Stopwatch sw) => '(${sw.elapsedMilliseconds} ms)';

  String _describe(Object error) {
    if (error is Error) return error.toString();
    return error.toString();
  }

  // ------------------------------------------------------------------ 落盘

  void _scheduleFlush() {
    if (_pending.isEmpty) return;
    _flushTimer ??= Timer(const Duration(milliseconds: 900), () {
      _flushTimer = null;
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    if (_pending.isEmpty) return;
    if (_pending.length > 400) {
      // 极端情况下（卡死后的日志雪崩）只保留最近的，避免一次写入过大。
      _pending.removeRange(0, _pending.length - 400);
    }
    final batch = _pending.join('\n');
    _pending.clear();
    await NativeBridge.instance.logAppend('$batch\n');
  }

  /// 立刻把待写内容落盘（退出页面、清空等场景调用）。
  Future<void> flush() => _flush();

  /// 启动时把上次运行留下的日志读回内存。
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    try {
      final text = await NativeBridge.instance.logRead();
      if (text == null || text.trim().isEmpty) return;
      final lines = const LineSplitter().convert(text);
      final tail = lines.length > _restoreLines
          ? lines.sublist(lines.length - _restoreLines)
          : lines;
      final restored = <LogEntry>[];
      for (final l in tail) {
        final e = _parse(l);
        if (e != null) restored.add(e);
      }
      if (restored.isEmpty) return;
      _entries.insertAll(0, restored);
      if (_entries.length > maxEntries) {
        final over = _entries.length - maxEntries;
        _entries.removeRange(0, over);
        _dropped += over;
      }
      notifyListeners();
    } catch (_) {
      // 回读失败不影响使用。
    }
  }

  /// 解析一行 `2026-09-15 23:41:02.183 I net  message`。
  static LogEntry? _parse(String line) {
    final m = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3}) ([DIWE]) (\w+)\s+(.*)$',
    ).firstMatch(line);
    if (m == null) return null;
    int g(int i) => int.tryParse(m.group(i)!) ?? 0;
    final level = LogLevel.values.firstWhere(
      (v) => v.letter == m.group(8),
      orElse: () => LogLevel.info,
    );
    return LogEntry(
      seq: 0,
      at: DateTime(g(1), g(2), g(3), g(4), g(5), g(6), g(7)),
      level: level,
      tag: LogTag.fromKey(m.group(9) ?? 'app'),
      message: m.group(10) ?? '',
    );
  }

  /// 清空内存与磁盘日志。
  Future<void> clear() async {
    _pending.clear();
    _entries.clear();
    _dropped = 0;
    _seq = 0;
    await NativeBridge.instance.logClear();
    notifyListeners();
  }

  /// 导出为纯文本（用于复制/分享）。
  List<String> toLines({bool newestFirst = true}) {
    final list = newestFirst ? entries : _entries;
    return [for (final e in list) e.fileLine];
  }

  /// 当前日志文件大小（字节）。
  Future<int> fileSize() => NativeBridge.instance.logSize();
}

/// 便捷入口：`log.d(LogTag.net, '...')`。
final AppLog log = AppLog.instance;
