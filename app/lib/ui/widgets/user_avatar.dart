import 'package:flutter/material.dart';

import '../../api/models.dart';
import 'net_image.dart';

/// 用户头像。
///
/// 契约给出 `avatar_url` 与 `avatar_color`：有图时显示图，
/// 无图时用 `avatar_color` 做底色 + 昵称首字，保持列表视觉稳定。
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.user,
    this.size = 36,
  });

  final SimpleUser user;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = user.avatarUrl;
    final bg = Color(user.avatarColorValue ?? 0xFFD8DEE9);
    final initial =
        user.nickname.isNotEmpty ? user.nickname.characters.first : '?';

    return ClipOval(
      child: NetImage(
        url: url,
        width: size,
        height: size,
        backgroundColor: bg,
        fallback: _fallback(bg, initial),
      ),
    );
  }

  Widget _fallback(Color bg, String initial) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}
