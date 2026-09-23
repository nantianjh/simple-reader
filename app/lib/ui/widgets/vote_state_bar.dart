import 'package:flutter/material.dart';

import '../../data/vote_states.dart';
import '../theme.dart';

/// 点赞按钮下方**原位展开**的表态条（长按点赞按钮开关）。
///
/// 形态刻意做成"快捷评论条"的同构件（见 `post_card.dart` 的
/// `_composerOpen` / `_inlineComposer`）：卡片自己摊开一条、展开前先走
/// 列表锚点，本组件只负责**画这一条**并把选中结果回调出去 ——
/// **不做网络、不弹层、不碰 Overlay、不带展开动画**。这是本工程里已经跑
/// 通的那套高度变化处理方式，不引入第二种定位机制，风险最小。
///
/// 每一项都是**会真实发出去的状态**：文案用服务端下发的那句原话
/// （长按某一项可以看到完整的一句，如 `🫂轻轻安慰了你`；条上空间只放
/// 短名）。可送出的状态表见 `data/vote_states.dart`，本机不润色、不猜值。
class VoteStateBar extends StatelessWidget {
  const VoteStateBar({
    super.key,
    required this.current,
    required this.onPick,
  });

  /// 我这条动态当前送出的表态 id（普通赞 / 没送过为 null）。
  final String? current;

  /// 点某一项：把它的 `vote_type` 交出去（发送交给 `sendVoteState`）。
  final ValueChanged<String> onPick;

  /// 条高：一行胶囊，尽量矮 —— 卡片高度变化越小，列表越好收尾。
  static const double height = 34;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // 宽度显式撑满：条挂在 Column 里（交叉轴是 loose 约束），
      // 不写死会出现"条自己缩到内容宽度"的对齐意外。
      width: double.infinity,
      height: height + 7,
      child: Padding(
        padding: const EdgeInsets.only(top: 7),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          // 不吸附、不回弹：这排就是横向看全十个，不做花活。
          physics: const ClampingScrollPhysics(),
          itemCount: VoteStates.all.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (_, i) {
            final s = VoteStates.all[i];
            return _chip(s, selected: s.id == current);
          },
        ),
      ),
    );
  }

  Widget _chip(VoteState s, {required bool selected}) {
    final color = selected ? AppTheme.likeColor : AppTheme.inkSecondary;
    return Tooltip(
      // 完整文案（服务端那句）；手机上长按胶囊即见。
      message: s.caption,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: () => onPick(s.id),
        borderRadius: BorderRadius.circular(height / 2),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.likeColor.withValues(alpha: 0.10)
                : AppTheme.surfaceMuted,
            borderRadius: BorderRadius.circular(height / 2),
            border: Border.all(
              color: selected
                  ? AppTheme.likeColor.withValues(alpha: 0.45)
                  : AppTheme.divider,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(s.emoji, style: const TextStyle(fontSize: 14, height: 1.0)),
              const SizedBox(width: 4),
              Text(
                s.short,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
