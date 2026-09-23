import 'package:flutter/material.dart';

import 'app_state.dart';

/// 全局状态注入。
///
/// 用 SDK 自带的 [InheritedNotifier] 实现，替代 provider 包：
/// [InheritedNotifier] 内部会监听 [AppState]（一个 [ChangeNotifier]），
/// 通知时自动重建依赖它的 widget。
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({
    super.key,
    required AppState state,
    required super.child,
  }) : super(notifier: state);

  /// 订阅式读取：状态变化时调用方会 rebuild（等价于 provider 的 `watch`）。
  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    if (scope == null) {
      throw FlutterError(
        'AppScope 未找到。请确认 AppScope 位于 widget 树中 MaterialApp 之上。',
      );
    }
    return scope.notifier!;
  }

  /// 一次性读取，不建立依赖（等价于 provider 的 `read`）。
  /// 适合在事件回调、initState 里取用。
  static AppState read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    if (scope == null) {
      throw FlutterError(
        'AppScope 未找到。请确认 AppScope 位于 widget 树中 MaterialApp 之上。',
      );
    }
    return scope.notifier!;
  }
}
