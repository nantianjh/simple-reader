import 'package:flutter/material.dart';

/// 让子树跟随**明暗切换**重建。
///
/// 为什么需要它：本工程的语义色是静态 getter（`AppTheme.inkPrimary` 之类），
/// **读它不会注册任何 InheritedWidget 依赖**。于是主题一变，只有那些依赖
/// Theme / MediaQuery 的 widget 会被通知重建；已经把内容挂在屏幕上的页面
/// （例如搜索页空态、缓存来源提示）不会重建，配色就停在旧主题上。
///
/// 依赖口径（2026-09-22 修正）：
/// * **取「生效亮度」= `Theme.of(context).brightness`** —— 它同时覆盖两条
///   路径：① 在设置里手动切「浅色 / 深色」（ThemeData 换了一份）；
///   ② 「跟随系统」时系统明暗变化（`MaterialApp` 自己读平台亮度并换主题）。
/// * ⚠️ 修之前这里只读 `MediaQuery.platformBrightnessOf`，于是**手动切换**
///   时平台亮度根本没变 → 本组件不重建 → 内容区停在旧配色；而 AppBar、
///   底部导航这些走 `Theme.of` 的部分正常变色。用户看到的就是
///   "从深色切回浅色，页面内容区没换色、非内容区换了"（v1.9.6 修复）。
///
/// 用法：页面根节点交给 [builder]。
/// ```dart
/// return BrightnessAware(builder: (context, _) => Scaffold(...));
/// ```
///
/// 两个必须守住的细节：
/// 1. 内部先读一次亮度建立依赖，亮度一变本 widget 即重建，再经 builder
///    产出**新的**子树 —— 子 widget 不是同一实例，框架会真正重建它们；
/// 2. 必须用 `builder` 而不是 `child`：传 `child` 时重建后子 widget 仍是同一
///    实例，框架按 `widget == newWidget` 直接复用、跳过 rebuild，等于白包。
///
/// State 不受影响：位置与类型都没变，滚动位置、输入内容、正在展开的面板都会
/// 原样保留，只是重新执行一遍 build。
class BrightnessAware extends StatelessWidget {
  const BrightnessAware({super.key, required this.builder});

  /// 子树的构建回调。第二个参数是当前**生效**亮度，方便调用方按需分支使用。
  final Widget Function(BuildContext context, Brightness brightness) builder;

  @override
  Widget build(BuildContext context) {
    // 这一读即注册了对 Theme 的依赖：手动切主题、跟随系统切明暗都会让它
    // 失效重建（详见类注释的依赖口径）。
    return builder(context, Theme.of(context).brightness);
  }
}
