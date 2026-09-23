import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import 'image_saver.dart';
import 'widgets/net_image.dart';

/// 全屏图片查看器。
///
/// 缩放/平移不用 [InteractiveViewer]：它与外层 [PageView] 的横向拖拽
/// 在手势竞技场里互相抢——双指捏合常被横向拖拽判赢（表现成"捏合完全
/// 无响应"或误翻页），放大之后 PageView 又会抢走缩小手势（表现成
/// "放大后捏不回来"）。这里改为：
///
/// * **双指捏合立即接管**：自定义 [PinchGestureRecognizer] 在第二根
///   手指落下的瞬间就宣布胜利（不等移动越阈值），捏合永远赢过翻页；
///   单指滑动在未放大时完全让给 PageView（不注册进竞技场）。
/// * **焦点锚定的缩放/平移**：保持"手指按住的那个点"在缩放过程中
///   不漂移，缩放与拖动用同一套公式（焦距移动 = 平移）。
/// * **放大后锁翻页**：scale > 1 时 PageView 切到不可滚动，平移与
///   缩小手势不再被翻页打断；缩回 ≤1 时自动弹回原尺寸并恢复翻页。
///   **例外**：长图的自动缩放不锁翻页（见 `_ZoomableImage._maybeAutoScale`），
///   否则长图一打开就滑不到下一张。
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.images,
    this.initialIndex = 0,
  });

  final List<MediaItem> images;
  final int initialIndex;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final PageController _controller;
  late int _index;

  /// 放大中的页面不允许翻页（否则缩小手势会被翻页抢走）。
  bool _zoomed = false;

  /// 各页的"是否锁住翻页"由每页自己上报。
  ///
  /// 不能只用变换矩阵推断：长图的**自动缩放**（见 `_ZoomableImage`）也是
  /// scale > 1，但它属于"打开时的初始展示"，不该锁住翻页 —— 否则长图一打开
  /// 就再也滑不到下一张。只有用户的捏合放大才锁。
  final Map<int, bool> _lockByIndex = <int, bool>{};

  /// 保存进行中（AppBar 按钮转圈 + 防重复触发）。
  bool _saving = false;

  /// 每页一个变换控制器：切页时各自复位，互不影响。
  final Map<int, TransformationController> _transforms = {};

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.images.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    for (final t in _transforms.values) {
      t.dispose();
    }
    super.dispose();
  }

  TransformationController _transformFor(int index) {
    return _transforms.putIfAbsent(index, () => TransformationController());
  }

  /// 保存当前页图片到相册。保存中按钮转圈，结束由 [saveMediaImage] 弹结果。
  Future<void> _saveCurrent() async {
    if (_saving || widget.images.isEmpty) return;
    setState(() => _saving = true);
    try {
      await saveMediaImage(context, widget.images[_index]);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          '${_index + 1} / ${widget.images.length}',
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white70),
              ),
            )
          else
            IconButton(
              tooltip: '保存图片',
              onPressed: _saveCurrent,
              icon: const Icon(Icons.download_rounded, size: 22),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.images.length,
        // 放大时锁住翻页：平移/缩小手势不再与翻页竞争。
        physics: _zoomed
            ? const NeverScrollableScrollPhysics()
            : const ClampingScrollPhysics(),
        onPageChanged: (i) {
          final locked = _lockByIndex[i] ??
              (_transformFor(i).value.getMaxScaleOnAxis() > 1.01);
          setState(() {
            _index = i;
            _zoomed = locked;
          });
        },
        itemBuilder: (context, i) {
          final m = widget.images[i];
          return _ZoomableImage(
            media: m,
            transform: _transformFor(i),
            onZoomChanged: (z) {
              _lockByIndex[i] = z;
              if (_index == i && _zoomed != z) {
                setState(() => _zoomed = z);
              }
            },
          );
        },
      ),
    );
  }
}

/// 单页可缩放图片。
///
/// 判定与变换都在这一层：RawGestureDetector 挂 [PinchGestureRecognizer]，
/// 缩放/平移统一走「焦点锚定」公式，边界钳制保证放大后图片不会被拖出视口。
class _ZoomableImage extends StatefulWidget {
  const _ZoomableImage({
    required this.media,
    required this.transform,
    required this.onZoomChanged,
  });

  final MediaItem media;
  final TransformationController transform;
  final void Function(bool zoomed) onZoomChanged;

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage>
    with SingleTickerProviderStateMixin {
  static const double _minScale = 1.0;
  static const double _maxScale = 5.0;

  /// 视为"放大"的阈值（含少量容差，避免浮点抖动）。
  static const double _zoomThreshold = 1.01;

  /// 变换控制器由查看器页持有（按页缓存、切页可复位），本组件只是使用方。
  TransformationController get _transform => widget.transform;

  /// 缩回原尺寸的弹回动画。
  late final AnimationController _snapBack;
  Animatable<Matrix4>? _snapTween;

  // 手势进行中的基准状态。
  Matrix4? _startTransform;
  double _startScale = 1.0;
  Offset? _startChildPoint;

  /// 视口尺寸（LayoutBuilder 里记录），边界钳制用。
  Size _viewport = Size.zero;

  /// 当前页是否"放大到需要锁住翻页"（判定与上报都在本页内部完成）。
  bool _zoomed = false;

  /// 长图自动缩放：是否已给出最终结论（应用过，或确定不需要）。
  bool _autoScaleResolved = false;

  /// 图片的**真实解码尺寸**（由 `ImageStream` 回来时填写）。
  ///
  /// ⚠️ 不能只信服务端下发的 `media.width/height`：实测大量图片这两个字段
  /// 是 0，于是"长图铺满宽度"的判定被整体跳过 —— 用户看到的就是"长图点开后
  /// 左右仍有黑边、根本没缩放"。
  Size? _intrinsicSize;

  /// 是否已经发起过真实尺寸的解析（见 [_resolveIntrinsicSize]）。
  bool _intrinsicRequested = false;

  /// 已应用的自动缩放倍率。捏合的上限要跟着它抬高（见 [_onScaleUpdate]）。
  double _appliedAutoScale = 1.0;

  /// 自动缩放的上限。
  ///
  /// **刻意不沿用 [_maxScale]**：极长图（20:1）铺满宽度需要的倍率远超 5，
  /// 夹到 5 仍然填不满、黑边照旧。捏合的 1~5 是"用户额外放大"的区间，
  /// 与"打开时的初始展示"是两码事。
  static const double _autoScaleCeiling = 20.0;

  /// 当前的放大**只**来自长图自动缩放（用户还没有双指捏过）。
  ///
  /// 用它把"打开时长图铺满宽度"与"用户自己放大"区分开：前者不锁翻页
  /// （长图也要能左右滑到下一张），且横向不允许拖（那一档正好铺满宽度）。
  bool _autoScaleOnly = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransformChanged);
    _snapBack = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 170),
    );
    _snapBack.addListener(() {
      final tween = _snapTween;
      if (tween != null) {
        _transform.value = tween.evaluate(_snapBack);
      }
    });
  }

  @override
  void dispose() {
    // 控制器本体归查看器页所有并统一销毁，这里只摘掉监听。
    _transform.removeListener(_onTransformChanged);
    _snapBack.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    // 弹回动画过程会改 transform，这里只负责向外同步"是否放大"。
    //
    // 自动缩放（长图铺满宽度）不算"用户放大"：对它一律上报 false，翻页手势
    // 因此保留 —— 否则长图一打开就再也滑不到下一张。用户一旦自己双指捏合，
    // [_autoScaleOnly] 复位，回到既有的"放大即锁翻页"口径。
    final zoomed = _transform.value.getMaxScaleOnAxis() > _zoomThreshold;
    final effective = zoomed && !_autoScaleOnly;
    if (effective != _zoomed) {
      _zoomed = effective;
      widget.onZoomChanged(effective);
    }
  }

  /// 真实尺寸只解析一次（需要继承的媒体信息，不能放在 initState）。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_intrinsicRequested) return;
    _intrinsicRequested = true;
    _resolveIntrinsicSize();
  }

  /// 解析图片的真实解码尺寸。
  ///
  /// 用与 `NetImage` 同一个 [NetworkImage] provider（同 url + 同 scale →
  /// 命中同一个 [ImageCache]，不会多下一次）。
  void _resolveIntrinsicSize() {
    final url = widget.media.url;
    if (url.isEmpty) return;
    final stream =
        NetworkImage(url).resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        if (!mounted) return;
        final image = info.image;
        if (image.width <= 0 || image.height <= 0) return;
        setState(() {
          _intrinsicSize = Size(
            image.width.toDouble(),
            image.height.toDouble(),
          );
        });
      },
      onError: (_, __) => stream.removeListener(listener),
    );
    stream.addListener(listener);
  }

  /// 长图打开时自动放大到铺满宽度。
  ///
  /// 背景：`BoxFit.contain` 会把"比视口更瘦长"的图压成很窄的一条 —— 10:1 的
  /// 长图在 400×800 的视口里只剩 40dp 宽，两侧留出大片黑边。这里按"铺满
  /// 宽度"反算初始缩放：
  ///
  ///   s = (图高 / 图宽) ÷ (视口高 / 视口宽)
  ///
  /// s ≤ 1 说明 contain 已经填满宽度（普通图、宽图、不比视口瘦长的图），
  /// 原样不动；s > 1 才放大，放大后纵向靠平移浏览。
  ///
  /// 判定优先用**真实解码尺寸**（[_intrinsicSize]），服务端字段只用来提前
  /// 出效果 —— 实测服务端对大量图片下发 width/height=0，只信它等于整条
  /// 逻辑静默失效（用户报的"长图点开后仍有黑边"即此）。
  ///
  /// 三条不覆盖原则：已经缩放过的（用户手捏过，或切页回来时控制器里还留着
  /// 上一次的值）不动；尺寸未知的不动（等真实尺寸回来再算）；不比视口瘦长的
  /// 不动。
  void _maybeAutoScale() {
    if (_autoScaleResolved) return;
    final viewport = _viewport;
    if (viewport.width <= 0 || viewport.height <= 0) return;

    final intrinsic = _intrinsicSize ?? _metaSize();
    if (intrinsic == null) return;
    // 真实尺寸到手才算最终结论；服务端字段只作提前生效用。
    if (_intrinsicSize != null) _autoScaleResolved = true;

    if (_transform.value.getMaxScaleOnAxis() > _zoomThreshold) {
      _autoScaleResolved = true; // 已有缩放（用户捏过 / 已自动过）→ 不覆盖
      return;
    }
    final s = (intrinsic.height / intrinsic.width) /
        (viewport.height / viewport.width);
    if (s <= _zoomThreshold) return;

    _autoScaleResolved = true;
    _autoScaleOnly = true;
    final target = s.clamp(_minScale, _autoScaleCeiling).toDouble();
    _appliedAutoScale = target;
    // 直接写控制器会触发 AnimatedBuilder 重建，放到本帧之后再写。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_transform.value.getMaxScaleOnAxis() > _zoomThreshold) return;
      _autoScaleOnly = true;
      _transform.value = Matrix4.identity()
        ..scaleByDouble(target, target, target, 1);
    });
  }

  /// 服务端下发的图片尺寸（可能为 0；只用于在真实尺寸回来前提前生效）。
  Size? _metaSize() {
    final m = widget.media;
    if (m.width <= 0 || m.height <= 0) return null;
    return Size(m.width.toDouble(), m.height.toDouble());
  }

  void _onScaleStart(ScaleStartDetails details) {
    _snapBack.stop();
    _snapTween = null;
    _startTransform = _transform.value.clone();
    _startScale = _startTransform!.getMaxScaleOnAxis();
    // 手势开始时焦点覆盖的子坐标：c = (f - t) / s。
    final tr = _startTransform!.getTranslation();
    final startTranslation = Offset(tr.x, tr.y);
    _startChildPoint =
        (details.localFocalPoint - startTranslation) / _startScale;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_startChildPoint == null || _startTransform == null) return;
    // 未放大 + 单指：不处理，单指滑动完整交给 PageView 翻页。
    if (_startScale <= _zoomThreshold && details.pointerCount < 2) return;
    // 双指 = 用户在主动缩放：长图自动缩放的身份到此结束，之后按"放大即锁
    // 翻页"的常规口径走（单指平移不算 —— 长图恰恰要靠单指纵向浏览）。
    if (details.pointerCount >= 2) _autoScaleOnly = false;

    // 上限跟着初始自动缩放走：长图铺满宽度可能已经超过 [_maxScale]，若把
    // 捏合上限钉死在 5，第一次捏合会把画面**缩小**（手感像"捏一下反而缩了"）。
    final ceiling = math.max(_maxScale, _appliedAutoScale);
    final target = (_startScale * details.scale)
        .clamp(_minScale, ceiling)
        .toDouble();
    // 焦点锚定：让"抓取点"始终跟随当前焦点（缩放与平移同一公式）。
    final focal = details.localFocalPoint;
    var translation = focal - _startChildPoint! * target;
    translation = _clampTranslation(translation, target);

    _transform.value = Matrix4.identity()
      ..translateByDouble(translation.dx, translation.dy, 0, 1)
      ..scaleByDouble(target, target, target, 1);
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final scale = _transform.value.getMaxScaleOnAxis();
    if (scale <= _zoomThreshold) {
      // 缩回（或本来就没放大成功）：弹回原尺寸，交还翻页。
      _snapTween = Matrix4Tween(
        begin: _transform.value.clone(),
        end: Matrix4.identity(),
      ).chain(CurveTween(curve: Curves.easeOutCubic));
      _snapBack
        ..reset()
        ..forward();
    }
  }

  /// 平移边界钳制：scale ≥ 1 时图片必须始终盖住视口。
  /// 缩放量为 1 时任何平移都被钳回零点（捏合"原地不动"）。
  Offset _clampTranslation(Offset t, double scale) {
    if (scale <= 1.0 || _viewport.isEmpty) return Offset.zero;
    // 长图自动缩放这一档：图片恰好在水平方向铺满视口，横向不该能拖 ——
    // 否则一拖就把图拉出屏幕、露出黑边（正好把"自适应铺满"的效果毁掉）。
    // 纵向仍按视口范围钳制（长图靠纵向平移浏览）。
    if (_autoScaleOnly) {
      final maxYOnly = _viewport.height * (scale - 1);
      return Offset(0, t.dy.clamp(-maxYOnly, 0.0).toDouble());
    }
    final maxX = _viewport.width * (scale - 1);
    final maxY = _viewport.height * (scale - 1);
    return Offset(
      t.dx.clamp(-maxX, 0.0).toDouble(),
      t.dy.clamp(-maxY, 0.0).toDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        // 长图按"铺满宽度"给出初始缩放（尺寸未知时先不动，等 ImageStream）。
        _maybeAutoScale();
        return ClipRect(
            child: RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: {
                PinchGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                        PinchGestureRecognizer>(
                  () => PinchGestureRecognizer(),
                  (instance) {
                    instance.onStart = _onScaleStart;
                    instance.onUpdate = _onScaleUpdate;
                    instance.onEnd = _onScaleEnd;
                  },
                ),
              },
            child: AnimatedBuilder(
              animation: _transform,
              builder: (context, _) => Transform(
                transform: _transform.value,
                child: SizedBox.expand(
                  child: Center(
                    child: NetImage(
                      url: widget.media.url,
                      fit: BoxFit.contain,
                      backgroundColor: Colors.transparent,
                      errorIcon: Icons.image_not_supported_outlined,
                      iconColor: Colors.white38,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 双指捏合识别器。
///
/// [ScaleGestureRecognizer] 的默认判定要等移动越过阈值才参与竞争，
/// 与 PageView 的横向拖拽势均力敌，谁赢取决于手指轨迹——这就是
/// "捏合有时完全没反应"的根源。这里改成：**第二根手指落下的瞬间
/// 就认输为胜（eagerWinner）**，翻页识别器还没来得及过阈值，
/// 捏合因此是确定性的。
///
/// ⚠️ 关键约束（v1.8.0 两次崩溃的教训）：**所有指针事件必须全量
/// 放行给父类，一个都不能过滤**。原因：
/// * 父类的 `_currentFocalPoint` 只在 handleEvent 里计算且从不清空，
///   竞技场裁决（eagerWinner 在 arena close 时同步生效）一定发生在
///   down 事件送达父类之后——只要父类见过 down，acceptGesture→onStart
///   就不会空指针崩溃；一旦过滤 down，裁决时刻父类状态还是空的。
/// * `_pointerQueue` 与 `_pointerLocations` 只在父类 handleEvent 里
///   同步增删，过滤会打破 `_updateLines` 的 `queue.length >= count`
///   不变量（RangeError 的来源）。
/// * 单指滑动的安全性不靠过滤保证：scale 识别器的 panSlop 是
///   kPanSlop（=2×kTouchSlop，36px），横向拖拽识别器 18px 就接手，
///   单指翻页永远更快——这也是 InteractiveViewer 官方默认行为。
class PinchGestureRecognizer extends ScaleGestureRecognizer {
  PinchGestureRecognizer();

  /// 在屏指针集合（用 Set 而非计数：reject/up/cancel 可能重复到达，
  /// 集合天然幂等，避免计数漂移后误判"双指"）。
  final Set<int> _livePointers = <int>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    // 顺序不可换：先让父类登记路由与内部状态，再决定是否接管。
    super.addAllowedPointer(event);
    _livePointers.add(event.pointer);
    if (_livePointers.length >= 2) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _livePointers.remove(event.pointer);
    }
    // 全量放行（含终止事件）——见类注释的不变量约束。
    super.handleEvent(event);
  }

  @override
  void rejectGesture(int pointer) {
    // 被翻页赢走的那根手指不再属于本识别器。
    _livePointers.remove(pointer);
    super.rejectGesture(pointer);
  }
}
