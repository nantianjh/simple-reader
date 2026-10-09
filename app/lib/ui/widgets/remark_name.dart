import 'package:flutter/material.dart';

import '../../data/user_remarks.dart';

/// 昵称文本：自动套用本机备注。
///
/// 展示口径（2026-09-23 需求 3）：设了备注就显示「**本名（备注名）**」，
/// 没设就显示本名。**应用里所有显示昵称的地方都用它** —— 在他人主页加完
/// 备注，信息流、详情页、评论区、合集作者名会一起变（内部订阅
/// [UserRemarksStore]，无需各页面自己重建）。
///
/// [prefix] / [suffix] 供「回复 @某人」「作者 某人」这类带前后缀的句子
/// 复用同一套口径，避免各处手写字符串拼接而漏掉备注。
class RemarkedText extends StatelessWidget {
  const RemarkedText({
    super.key,
    required this.nickname,
    required this.userId,
    required this.style,
    this.prefix = '',
    this.suffix = '',
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
  });

  /// 接口给的最新本名。
  final String nickname;

  /// 该用户的 id（备注按 id 匹配，改名后依然生效）。
  final String userId;

  final TextStyle style;
  final String prefix;
  final String suffix;
  final int? maxLines;
  final TextOverflow overflow;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: UserRemarksStore.instance,
      builder: (context, _) => Text(
        '$prefix${UserRemarksStore.instance.display(nickname, userId)}$suffix',
        maxLines: maxLines,
        overflow: overflow,
        style: style,
      ),
    );
  }
}
