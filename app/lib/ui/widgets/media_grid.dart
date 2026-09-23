import 'package:flutter/material.dart';

import '../../api/api_config.dart';
import '../../api/models.dart';
import '../../util/links.dart';
import '../actions.dart';
import '../image_saver.dart';
import '../image_viewer_page.dart';
import '../theme.dart';
import 'net_image.dart';

/// 媒体九宫格。
///
/// 按数量自适应：1 张给大图，2 张并排，>=3 张三列。
///
/// 三类特殊项不按普通图片处理：
/// * 链接卡片（服务端把正文 URL 转成的卡片）——显示为可点击的链接条，
///   点击默认用应用内 WebView 打开（设置可关）；
/// * heic/heif 等可转码图片——先经七牛 `format/jpg` 转码尝试显示，
///   转不出来再显示准确的类型标签；
/// * 实况照片及未知类型——显示准确的类型占位，不发起无效加载。
class MediaGrid extends StatelessWidget {
  const MediaGrid({
    super.key,
    required this.media,
    this.maxVisible = 9,
  });

  final List<MediaItem> media;
  final int maxVisible;

  @override
  Widget build(BuildContext context) {
    if (media.isEmpty) return const SizedBox.shrink();

    final visible = media.take(maxVisible).toList();
    final extra = media.length - visible.length;

    if (visible.length == 1) {
      return _single(context, visible.first);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 4.0;
        final columns = visible.length == 2 ? 2 : 3;
        final tile =
            (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (var i = 0; i < visible.length; i++)
              _tile(
                context,
                visible[i],
                tile,
                overlayCount: (i == visible.length - 1 && extra > 0) ? extra : null,
              ),
          ],
        );
      },
    );
  }

  /// 单图预览宽度相对「原分辨率换算结果」的缩放系数。
  ///
  /// 需求（用户二次反馈）：只按原分辨率显示**仍然显得过大**，预览图缩到
  /// 当前口径的四分之一 —— 即宽、高各取 1/4（1080px 的图在 3x 屏上由
  /// 约 360dp 宽变为约 90dp 宽）。要改成"面积缩到 1/4"（宽高各减半）
  /// 只需把这个值改成 0.5。
  static const double _singleScale = 0.25;

  /// 缩放后显示宽度的下限（逻辑像素）。
  ///
  /// 原图本身就很小的（例如 320px 的旧图在 3x 屏上只有约 107dp）再缩 1/4
  /// 会小到看不清，这里给个下限兜住；下限**不会超过**原分辨率换算宽度，
  /// 因此仍然满足"不放大"这条硬约束（下方 `floor` 的取法保证这一点）。
  static const double _singleMinWidth = 64;

  /// 单张媒体。
  ///
  /// 需求明确：只有一张图时**不要放大**，保持它自己的分辨率尺寸；
  /// 二次反馈后又要求在此基础上再缩到四分之一（[`_singleScale`]）。
  /// 因此这里不撑满可用宽度，而是：
  /// * 用服务端给出的原始像素宽（`width`）除以设备像素比换算成逻辑像素 ——
  ///   这是"不放大"的基准；
  /// * 基准再乘 [`_singleScale`]，并用 [`_singleMinWidth`] 兜住小图；
  /// * 高宽比用图片自身的比例，以 `BoxFit.contain` 渲染，不裁切。
  /// 宽高信息缺失时（服务端偶尔不给）按可用宽度的同比例缩，比例未知时
  /// 沿用旧的温和钳制。
  Widget _single(BuildContext context, MediaItem m) {
    // 链接卡片单独成条，比塞进正方形格子里可读得多。
    // 注意必须排在实况照片占位之前，否则网页地址（无扩展名）会被误判成实况照片。
    if (m.isLinkCard) return _linkCard(context, m.linkUrl!);

    final hasSize = m.width > 0 && m.height > 0;
    final dpr = MediaQuery.of(context).devicePixelRatio;

    return LayoutBuilder(
      builder: (context, constraints) {
        final avail = constraints.maxWidth;

        if (hasSize) {
          // 「不放大」的基准：原图像素换算成逻辑像素，最多到可用宽度。
          var base = m.width / (dpr <= 0 ? 1 : dpr);
          if (base > avail) base = avail;
          final floor = base < _singleMinWidth ? base : _singleMinWidth;
          var width = base * _singleScale;
          if (width < floor) width = floor;
          return Align(
            alignment: Alignment.centerLeft,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: GestureDetector(
                onTap: () => _onTap(context, m),
                onLongPress: () => _onLongPress(context, m),
                child: SizedBox(
                  width: width,
                  height: width / m.aspectRatio,
                  child: _mediaChild(m, compact: false, fit: BoxFit.contain),
                ),
              ),
            ),
          );
        }

        // 尺寸缺失：按可用宽度的同比例缩，比例未知时钳到 0.6~1.6 这个温和区间。
        final ratio = m.aspectRatio.clamp(0.6, 1.6);
        var width = avail * _singleScale;
        if (width < _singleMinWidth) width = _singleMinWidth;
        return Align(
          alignment: Alignment.centerLeft,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: GestureDetector(
              onTap: () => _onTap(context, m),
              onLongPress: () => _onLongPress(context, m),
              child: SizedBox(
                width: width,
                height: width / ratio,
                child: _mediaChild(m, compact: false, fit: BoxFit.contain),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _tile(
    BuildContext context,
    MediaItem m,
    double size, {
    int? overlayCount,
  }) {
    return GestureDetector(
      onTap: () => _onTap(context, m),
      onLongPress: () => _onLongPress(context, m),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _mediaChild(m, compact: true),
              if (m.isLivePhoto)
                const Positioned(
                  left: 4,
                  top: 4,
                  child: Icon(Icons.motion_photos_on_outlined,
                      color: Colors.white70, size: 16),
                ),
              if (m.isLinkCard)
                const Positioned(
                  right: 4,
                  bottom: 4,
                  child: Icon(Icons.link_rounded, color: Colors.white, size: 18),
                ),
              if (overlayCount != null)
                Container(
                  color: Colors.black54,
                  alignment: Alignment.center,
                  child: Text(
                    '+$overlayCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (m.isVideo)
                const Positioned(
                  right: 4,
                  bottom: 4,
                  child: Icon(
                    Icons.play_circle_fill,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 单个媒体格的内容（九宫格与评论小图共用）。
  ///
  /// 判定顺序即准确性优先级：
  /// 链接卡片 → 可转码图片（尝试显示）→ 实况照片占位 → 视频/音频占位 → 普通图片。
  ///
  /// [fit] 由调用方决定：九宫格用 `cover`（格子是正方形，需要裁切填满），
  /// 单图用 `contain`（容器已按原图比例，不裁切、不放大）。
  /// [showLabel] 控制占位块是否带文字标签：九宫格/单图空间足够，带上更
  /// 明确；评论 56px 小图放不下文字，只显示图标。
  static Widget typeAwareChild(
    MediaItem m, {
    required bool compact,
    BoxFit fit = BoxFit.cover,
    bool showLabel = true,
  }) {
    if (m.isLinkCard) {
      return Container(
        color: AppTheme.surfaceMuted,
        alignment: Alignment.center,
        child: Icon(Icons.link_rounded,
            size: compact ? 24 : 26, color: AppTheme.accent),
      );
    }
    if (m.isTranscodableImage) {
      // heic/heif：先试七牛 format/jpg 转码显示；转不出来时回落到准确标签。
      return NetImage(
        url: m.transcodeUrl,
        fit: fit,
        errorIcon: Icons.motion_photos_on_outlined,
        iconColor: AppTheme.inkTertiary,
        fallback:
            _typeBlock(m, compact: compact, showLabel: showLabel),
      );
    }
    if (m.isLivePhoto) {
      return _typeBlock(m, compact: compact, showLabel: showLabel);
    }
    return _thumb(m, fit);
  }

  Widget _mediaChild(
    MediaItem m, {
    required bool compact,
    BoxFit fit = BoxFit.cover,
  }) {
    return typeAwareChild(m, compact: compact, fit: fit);
  }

  static Widget _thumb(MediaItem m, BoxFit fit) {
    // 缩略图追加七牛参数，避免列表拉原图（报告第四节）。
    final thumbUrl = m.url.contains('?')
        ? m.url
        : '${m.url}${ApiConfig.thumbSuffix}';

    if (m.isVideo) {
      return Container(
        color: AppTheme.surfaceMuted,
        alignment: Alignment.center,
        child: Icon(Icons.videocam_outlined,
            size: 28, color: AppTheme.inkTertiary),
      );
    }
    if (m.isAudio) {
      return Container(
        color: AppTheme.surfaceMuted,
        alignment: Alignment.center,
        child: Icon(Icons.audiotrack_outlined,
            size: 28, color: AppTheme.inkTertiary),
      );
    }
    if (m.isLinkCard) {
      return Container(
        color: AppTheme.surfaceMuted,
        alignment: Alignment.center,
        child: Icon(Icons.link_rounded, size: 26, color: AppTheme.accent),
      );
    }

    return NetImage(
      url: thumbUrl,
      fit: fit,
      errorIcon: Icons.broken_image_outlined,
      iconColor: AppTheme.inkDisabled,
    );
  }

  /// 无法直接解码时的占位：按可用信息给出准确的类型标签。
  static Widget _typeBlock(
    MediaItem m, {
    required bool compact,
    bool showLabel = true,
  }) {
    String label;
    if (m.typeSaysLivePhoto) {
      label = '实况照片';
    } else if (m.isAudio) {
      label = '音频';
    } else if (m.type.isEmpty) {
      label = '未知类型';
    } else {
      label = '暂不支持的类型';
    }
    return Container(
      color: AppTheme.surfaceMuted,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            label == '实况照片'
                ? Icons.motion_photos_on_outlined
                : Icons.help_outline_rounded,
            size: compact ? 20 : 26,
            color: AppTheme.inkTertiary,
          ),
          if (showLabel) ...[
            SizedBox(height: compact ? 3 : 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(
                fontSize: compact ? 11 : 12.5,
                color: AppTheme.inkTertiary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 链接条：域名 + 完整地址（过长时省略中段）。
  Widget _linkCard(BuildContext context, String url) {
    return InkWell(
      onTap: () => _openLink(context, url),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: AppTheme.infoBackground,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.accentBorder, width: 0.8),
        ),
        child: Row(
          children: [
            Icon(Icons.link_rounded, size: 17, color: AppTheme.accent),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hostOf(url),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.inkPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    shortenUrl(url),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.accent,
                      decoration: TextDecoration.underline,
                      decorationColor: AppTheme.accent.withValues(alpha: 0.34),
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.open_in_new_rounded,
                size: 15, color: AppTheme.inkTertiary),
          ],
        ),
      ),
    );
  }

  void _onTap(BuildContext context, MediaItem m) =>
      handleTap(context, media, m);

  /// 长按保存图片（九宫格与单图入口；查看器里另有 AppBar 按钮）。
  ///
  /// 只对能拿到图片的项生效：可解码图片直接存原图，heic/heif 等可转码
  /// 图片存转码后的 jpg。链接卡片 / 实况照片 / 音视频本就没有可保存的
  /// 静态图，长按不响应。
  void _onLongPress(BuildContext context, MediaItem m) =>
      handleLongPress(context, m);

  /// 点开一个媒体项 —— 九宫格与**评论小图**共用同一套口径。
  ///
  /// [group] 是同一组的全部媒体（动态的一组图、或某条评论里的图），
  /// 查看器里可以左右翻看同组的图。
  static void handleTap(
    BuildContext context,
    List<MediaItem> group,
    MediaItem m,
  ) {
    if (m.isLinkCard) {
      _openLink(context, m.linkUrl!);
      return;
    }
    if (m.isTranscodableImage) {
      // 走转码后的地址全屏查看。
      openViewer(context, group, m, urlOverride: m.transcodeUrl);
      return;
    }
    // 无法在应用内点开查看的特殊媒体（实况照片 / 音视频 / 未知类型）：
    // 统一指路「在 Simple 中打开」——那是官方分享页（会尝试深链唤起
    // 官方 App），是这类媒体目前唯一可靠的查看途径。
    if (m.isLivePhoto || m.isVideo || m.isAudio) {
      _toast(context, '请点击在simple中打开查看');
      return;
    }
    openViewer(context, group, m);
  }

  /// 长按保存（评论小图同样复用）。
  static void handleLongPress(BuildContext context, MediaItem m) {
    if (!m.isDecodableImage && !m.isTranscodableImage) return;
    saveMediaImage(context, m);
  }

  static Future<void> _openLink(BuildContext context, String url) async {
    // 统一入口：应用内 WebView 优先（设置可关），失败回退系统浏览器。
    final ok = await openLink(context, url);
    if (ok || !context.mounted) return;
    _toast(context, '没有可以打开该链接的应用');
  }

  static void _toast(BuildContext context, String msg) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2, milliseconds: 200),
        ),
      );
  }

  /// 打开全屏查看器（九宫格、单图、评论小图共用）。
  static void openViewer(
    BuildContext context,
    List<MediaItem> group,
    MediaItem tapped, {
    String? urlOverride,
  }) {
    // 能解码的图片直接交给查看器；heic 等可转码图片用转码地址参与浏览。
    final viewerItems = <MediaItem>[];
    for (final m in group) {
      if (m.isDecodableImage) {
        viewerItems.add(m);
      } else if (m.isTranscodableImage) {
        viewerItems.add(
          MediaItem(
            url: m.transcodeUrl,
            type: m.type,
            width: m.width,
            height: m.height,
            raw: m.raw,
          ),
        );
      }
    }
    if (viewerItems.isEmpty) return;
    var index =
        viewerItems.indexWhere((m) => m.url == (urlOverride ?? tapped.url));
    if (index < 0) index = 0;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ImageViewerPage(images: viewerItems, initialIndex: index),
      ),
    );
  }
}

/// 小尺寸媒体缩略（评论里的表情 / 图片用）。
///
/// 此前评论媒体直接 `NetImage(url)` 渲染，没走类型判定——实况照片
/// （`.mov` / `.heic` 地址或 type=live）会渲染成破图。现在与动态九宫格
/// 共用同一套规则：可解码图正常显示，heic/heif 先经七牛转码尝试，
/// 实况照片与视频/音频/链接卡片显示类型图标，不发起无效加载。
class MediaThumb extends StatelessWidget {
  const MediaThumb({super.key, required this.media, required this.size});

  final MediaItem media;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      // 56px 的小格子放不下文字标签，只显示类型图标。
      child: MediaGrid.typeAwareChild(media, compact: true, showLabel: false),
    );
  }
}
