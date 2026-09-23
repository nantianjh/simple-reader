import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../theme.dart';
import 'brightness_aware.dart';

/// 「关于」内容 —— 高级设置的关于卡与首次登录提示页**共用同一份**。
///
/// 口径：只讲两件事 —— 这是什么工具、请求边界与滥用后果。请求间隔、并发
/// 策略、缓存实现这些属于工程细节，不写进用户可见文案（原先那段
/// "所有请求均以 1.2 秒以上的间隔串行发送…"已按需求删除）。
class AboutContent extends StatelessWidget {
  const AboutContent({super.key});

  /// 请求边界与风险提示。单独抽成常量，便于提示页与关于卡保持字面一致。
  static const String usageNote = '本应用的全部数据均通过官方接口获取，'
      '不使用任何非官方手段。请勿使用脚本或自动化工具批量拉取内容——'
      '因违规滥用导致的账号限流、封禁等后果，由使用者自行承担。';

  /// 应用自称（署名行）。更名后统一为「Simple阅读」，不再带技术后缀。
  static const String appSignature = AppInfo.name;

  @override
  Widget build(BuildContext context) =>
      BrightnessAware(builder: (context, _) => _contents());

  Widget _contents() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          appSignature,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: AppTheme.inkPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '本应用为个人使用的检索工具，仅做只读检索与本人账号下的常规互动。',
          style: TextStyle(
            fontSize: 12.5,
            color: AppTheme.inkSecondary,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppTheme.warningBackground,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.warningBorder, width: 0.6),
          ),
          child: Text(
            usageNote,
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.warning,
              height: 1.55,
            ),
          ),
        ),
      ],
    );
  }
}

/// 首次登录进入主界面后的提示页：内容就是「关于」，只弹一次。
///
/// 需求调整：v1.9.1 起恢复"首次登录弹一次"的机制，但内容从原来的功能导览
/// 换成「关于」（功能导览改为在「我的 → 高级设置 → 功能导览」手动查看）。
/// 只弹一次的标记是 `AppSettings.aboutIntroShown`。
Future<void> showAboutIntroDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('关于 ${AppInfo.name}', style: TextStyle(fontSize: 17)),
      content: const SingleChildScrollView(child: AboutContent()),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
