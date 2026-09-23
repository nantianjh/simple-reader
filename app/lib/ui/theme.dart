import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 应用主题。
///
/// 克制、信息密度优先：这是一个阅读与检索工具，
/// 视觉层不应与内容抢注意力。
///
/// v1.7.2 起支持暗黑模式：颜色不再是编译期常量，而是按 [AppTheme.isDark]
/// 在运行时解析的 getter——浅色与深色各有一套取值，组件层只管引用语义色，
/// 不感知当前模式。根组件（main.dart）在主题模式变化时同步 [isDark]。
///
/// 注意：因为 getter 不是常量，引用它们的表达式**不能**再写 `const`
/// （例如 `const TextStyle(color: AppTheme.inkPrimary)` 会编译失败，
/// 应写作 `TextStyle(...)`，内层的 EdgeInsets 等仍可单独 const）。
class AppTheme {
  AppTheme._();

  /// 当前的明暗模式。true = 深色。由根组件在主题变化时写入。
  static bool isDark = false;

  // ------------------------------------------------------------ 调色板

  /// 主色（操作、链接、选中态）。
  static Color get accent => isDark ? const Color(0xFF5B8DEF) : const Color(0xFF2563EB);

  /// 页面底色。
  static Color get pageBackground => isDark ? const Color(0xFF101318) : const Color(0xFFF4F5F7);

  /// 卡片 / 列表行底色。
  static Color get cardBackground => isDark ? const Color(0xFF1A1F26) : Colors.white;

  /// 分隔线与描边。
  static Color get divider => isDark ? const Color(0xFF2A3038) : const Color(0xFFE8EAEE);

  /// 一级正文。
  static Color get inkPrimary => isDark ? const Color(0xFFE6E9EE) : const Color(0xFF1A1D23);

  /// 二级说明文字。
  static Color get inkSecondary => isDark ? const Color(0xFFA2ACBA) : const Color(0xFF5A6472);

  /// 三级弱化文字（时间、占位提示）。
  static Color get inkTertiary => isDark ? const Color(0xFF6F7A8B) : const Color(0xFF8A94A3);

  /// 禁用 / 极弱化（图标、已读标记、灰色圆点）。
  static Color get inkDisabled => isDark ? const Color(0xFF4A5260) : const Color(0xFFC3CAD4);

  /// 危险色（删除、错误）。
  static Color get danger => isDark ? const Color(0xFFEF5350) : const Color(0xFFDC2626);

  /// 成功色（有效状态、新用户标识）。
  static Color get success => isDark ? const Color(0xFF4ADE80) : const Color(0xFF0F7B4F);

  // ------------------------------------------------ 语义化的次级表面色

  /// 弱化底色：小标签、图标容器、筛选 chip 的底。
  static Color get surfaceMuted => isDark ? const Color(0xFF242A33) : const Color(0xFFF1F3F6);

  /// 次级底色：回复楼中楼、待发表情条等嵌套区块。
  static Color get surfaceAlt => isDark ? const Color(0xFF20252D) : const Color(0xFFF7F9FB);

  /// 主色弱化底：合集标签、「查看合集」胶囊的底。
  static Color get accentMutedBg => isDark ? const Color(0xFF1B2A41) : const Color(0xFFEEF3FE);

  /// 主色弱化描边：链接条边框。
  static Color get accentBorder => isDark ? const Color(0xFF2C3E5C) : const Color(0xFFDBE6F8);

  /// 信息提示条底色（缓存来源提示）。
  static Color get infoBackground => isDark ? const Color(0xFF15263C) : const Color(0xFFF3F7FE);

  /// 警示文字（琥珀色，到期提醒、同步失败）。
  static Color get warning => isDark ? const Color(0xFFF5B942) : const Color(0xFFB45309);

  /// 警示条底色。
  static Color get warningBackground => isDark ? const Color(0xFF2E2712) : const Color(0xFFFDF6E7);

  /// 警示条描边。
  static Color get warningBorder => isDark ? const Color(0xFF4A3F1E) : const Color(0xFFF0DFB8);

  /// 危险提示条底色（凭证失效横幅）。
  static Color get dangerBackground => isDark ? const Color(0xFF331A1C) : const Color(0xFFFDF0F0);

  /// 危险弱化描边（历史删除模式下的词条边框）。
  static Color get dangerBorder => isDark ? const Color(0xFF5C2A2E) : const Color(0xFFF3C9C9);

  /// 成功弱化底（「新」角标）。
  static Color get successBackground => isDark ? const Color(0xFF16301F) : const Color(0xFFE8F5EC);

  /// 点赞激活色。
  static Color get likeColor => isDark ? const Color(0xFFF87171) : const Color(0xFFE0565B);

  /// 收藏激活色。
  static Color get starColor => isDark ? const Color(0xFFFBBF24) : const Color(0xFFE8A33D);

  /// 网络图片占位底色。
  static Color get imagePlaceholder => isDark ? const Color(0xFF232830) : const Color(0xFFEDEFF3);

  /// SnackBar 底色。
  static Color get snackBarBackground => isDark ? const Color(0xFF39414B) : const Color(0xFF23272F);

  // ------------------------------------------------------------ 主题数据

  /// 浅色主题。
  static ThemeData light() => _build(Brightness.light);

  /// 深色主题。
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: dark ? const Color(0xFF5B8DEF) : accent,
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: pageBackground,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: cardBackground,
        foregroundColor: inkPrimary,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        ),
        titleTextStyle: TextStyle(
          color: inkPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: divider,
        thickness: 0.6,
        space: 0.6,
      ),
      cardTheme: CardThemeData(
        color: cardBackground,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: divider, width: 0.6),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cardBackground,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        hintStyle: TextStyle(color: inkTertiary, fontSize: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: accent, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: danger, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: inkPrimary,
          minimumSize: const Size(0, 44),
          side: BorderSide(color: divider),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceMuted,
        side: BorderSide.none,
        labelStyle: TextStyle(
          fontSize: 13,
          color: inkSecondary,
          fontWeight: FontWeight.w500,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: snackBarBackground,
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accent,
        linearMinHeight: 2,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: inkSecondary,
        textColor: inkPrimary,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardBackground,
        titleTextStyle: TextStyle(
          color: inkPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: TextStyle(
          color: inkPrimary,
          fontSize: 13.5,
          height: 1.6,
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: cardBackground,
        selectedItemColor: accent,
        unselectedItemColor: inkTertiary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        selectedLabelStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 11.5),
      ),
      textTheme: TextTheme(
        bodyMedium: TextStyle(fontSize: 14.5, color: inkPrimary, height: 1.55),
        bodySmall: TextStyle(fontSize: 12.5, color: inkSecondary),
        titleMedium: TextStyle(
          fontSize: 15.5,
          fontWeight: FontWeight.w600,
          color: inkPrimary,
        ),
      ),
    );
  }

  /// 按当前模式刷新系统状态栏样式（搜索页等没有 AppBar 的页面兜底）。
  ///
  /// AppBar 自带 AnnotatedRegion 会覆盖有栏页面的状态栏；这里只负责
  /// 无栏页面与全局初值。重复设置同一模式没有副作用，但为避免每次
  /// 重建都走一次通道，先比对上次已应用的模式。
  static Brightness? _lastApplied;
  static void applyStatusBarStyle() {
    if (_lastApplied == (isDark ? Brightness.dark : Brightness.light)) return;
    _lastApplied = isDark ? Brightness.dark : Brightness.light;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      ),
    );
  }
}
