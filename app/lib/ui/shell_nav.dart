import 'package:flutter/foundation.dart';

/// 底部导航的当前页。
///
/// 让「我的」页里的入口能直接把用户送到收藏夹，而不必再复制一份列表实现。
class ShellNav {
  ShellNav._();

  static const int search = 0;
  static const int favourites = 1;
  static const int me = 2;

  static final ValueNotifier<int> index = ValueNotifier<int>(search);

  static void go(int i) {
    if (index.value != i) index.value = i;
  }
}
