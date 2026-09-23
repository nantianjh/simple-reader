import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../theme.dart';
import 'net_image.dart';

/// 待随评论发送的表情条（横向缩略图列表，逐个可移除）。
///
/// 详情页评论栏与动态卡片的内联评论条共用。评论里的表情不是文本：
/// 按官方形态作为 media 图片项（`{type:"image", url}`）随 body 一起
/// 发送，这条横幅展示"待发"集合，点角标即移除。
class PendingEmojiStrip extends StatelessWidget {
  const PendingEmojiStrip({
    super.key,
    required this.emojis,
    required this.onRemove,
  });

  /// 待发集合（共享自调用方的状态，只读渲染）。
  final List<Emoji> emojis;

  /// 移除某个待发表情。
  final void Function(Emoji emoji) onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      margin: const EdgeInsets.only(bottom: 7),
      decoration: BoxDecoration(
        color: AppTheme.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(4),
        children: [
          for (final e in emojis)
            Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.all(3),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: NetImage(
                      url: e.thumbUrl,
                      width: 46,
                      height: 46,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  child: GestureDetector(
                    onTap: () => onRemove(e),
                    child: Container(
                      padding: const EdgeInsets.all(1),
                      decoration: const BoxDecoration(
                        color: Color(0xFF6B7280),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close_rounded,
                          size: 10, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
