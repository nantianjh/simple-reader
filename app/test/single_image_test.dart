import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_reader/api/models.dart';
import 'package:simple_reader/ui/widgets/media_grid.dart';
import 'package:simple_reader/ui/widgets/net_image.dart';

/// 单图预览尺寸的口径回归。
///
/// 需求演进过两轮：
/// 1. 单图**不放大** —— 以服务端原图宽 ÷ 设备像素比作为基准（1080px 的图在
///    3x 屏上 = 360dp）；
/// 2. 二次反馈"还是显示过大" → 预览图再缩到该基准的 1/4（= 90dp）。
///
/// 这两条都是纯布局计算，肉眼难复核，因此用测试锁住具体数值。
/// 小图有 64dp 下限兜底，避免 1/4 之后小到看不清。
Future<Size> _pumpSingle(WidgetTester tester, MediaItem m) async {
  // 3x 屏、可为单图提供 400dp 宽度。
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(width: 400, child: MediaGrid(media: [m])),
      ),
    ),
  ));
  await tester.pump();
  return tester.getSize(find.byType(NetImage));
}

MediaItem _image({required int width, required int height}) => MediaItem.fromJson({
      'url': 'https://static-simple.imsummer.cn/p/a.jpg',
      'type': 'image',
      'width': width,
      'height': height,
    });

void main() {
  testWidgets('单图按原分辨率的 1/4 显示（1080px 的图在 3x 屏上宽 90dp）',
      (tester) async {
    final size = await _pumpSingle(tester, _image(width: 1080, height: 810));

    // 基准 1080 / 3 = 360dp，取 1/4 = 90dp；高度按原比例 90 ÷ (1080/810)。
    expect(size.width, closeTo(90, 0.5));
    expect(size.height, closeTo(67.5, 0.5));
  });

  testWidgets('宽度超过可用宽度时先钳到可用宽度再取 1/4', (tester) async {
    // 4000 / 3 = 1333dp > 400dp 可用宽度 → 基准 400dp → 显示 100dp。
    final size = await _pumpSingle(tester, _image(width: 4000, height: 1000));

    expect(size.width, closeTo(100, 0.5));
    expect(size.height, closeTo(25, 0.5));
  });

  testWidgets('小图有 64dp 下限兜底，且绝不放大超过原分辨率', (tester) async {
    // 200 / 3 = 66.7dp 基准，1/4 只有 16.7dp → 抬到下限 64dp（仍小于基准）。
    final small = await _pumpSingle(tester, _image(width: 200, height: 150));
    expect(small.width, closeTo(64, 0.5));

    // 120 / 3 = 40dp 基准本身就低于下限 → 既不缩也没放大，保持 40dp。
    final tiny = await _pumpSingle(tester, _image(width: 120, height: 90));
    expect(tiny.width, closeTo(40, 0.5));
    expect(tiny.height, closeTo(30, 0.5));
  });

  testWidgets('尺寸缺失时按可用宽度的 1/4 缩，比例未知时用 3:4', (tester) async {
    final m = MediaItem.fromJson({
      'url': 'https://static-simple.imsummer.cn/p/a.jpg',
      'type': 'image',
    });
    final size = await _pumpSingle(tester, m);

    expect(size.width, closeTo(100, 0.5)); // 400 × 0.25
    expect(size.height, closeTo(400 / 3, 0.5)); // 100 ÷ 0.75
  });
}
