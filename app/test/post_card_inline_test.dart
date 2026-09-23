import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_reader/api/models.dart';
import 'package:simple_reader/state/app_scope.dart';
import 'package:simple_reader/state/app_state.dart';
import 'package:simple_reader/ui/widgets/post_card.dart';

/// v1.9.2 两项卡片交互的回归：
/// * 长文折叠态在正文第六行下方显示「−请展开阅读−」，点击展开；
/// * 点「评论」按钮在卡片内原位展开快捷评论条（不进详情页）。
///
/// 直接渲染单张卡片即可：_toggleComposer / _expandHint 走的
/// PagedPostListAnchor.maybeOf 在列表外返回 null（安全降级），
/// 不需要搭完整的分页列表环境。
Future<void> _pumpCard(
  WidgetTester tester, {
  required int textLength,
  bool withScope = false,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final card = PostCard(
    post: Post.fromJson({'id': 'p1', 'content': '啊' * textLength}),
    onTap: () {},
  );
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          if (withScope) AppScope(state: AppState(), child: card) else card,
        ],
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// 收尾：把日志系统 900ms 的落盘定时器跑完（否则 flutter_test 判
/// "A Timer is still pending"）。
Future<void> _drainLogTimer(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

void main() {
  testWidgets('长文折叠态显示「−请展开阅读−」，点击展开后隐藏', (tester) async {
    await _pumpCard(tester, textLength: 260);

    // 折叠态：提示行存在（居中一行，正文第六行下）。
    expect(find.text('−请展开阅读−'), findsOneWidget);
    // 折叠态下按钮栏是「展开全文」。
    expect(find.text('展开全文'), findsOneWidget);

    // 提示行在按钮栏上方（正文下方、动作栏之前）。
    final hintCenter = tester.getCenter(find.text('−请展开阅读−'));
    final actionsCenter = tester.getCenter(find.text('展开全文'));
    expect(hintCenter.dy, lessThan(actionsCenter.dy));

    // 点击提示行 → 展开：提示行消失，按钮栏变「收起」。
    await tester.tap(find.text('−请展开阅读−'));
    await tester.pumpAndSettle();
    expect(find.text('−请展开阅读−'), findsNothing);
    expect(find.text('收起'), findsOneWidget);

    await _drainLogTimer(tester);
  });

  testWidgets('短文不显示提示行', (tester) async {
    await _pumpCard(tester, textLength: 10);
    expect(find.text('−请展开阅读−'), findsNothing);
    expect(find.text('展开全文'), findsNothing);
    await _drainLogTimer(tester);
  });

  testWidgets('点「评论」按钮原位展开输入条，再点收起', (tester) async {
    await _pumpCard(tester, textLength: 260);

    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('评论'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('发送'), findsOneWidget);

    // 再点一次「评论」（此时按钮处于激活态）→ 收起。
    await tester.tap(find.text('评论'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);

    await _drainLogTimer(tester);
  });

  testWidgets('无 token 时发送内联评论给出配置指引（不发请求）', (tester) async {
    await _pumpCard(tester, textLength: 260, withScope: true);

    await tester.tap(find.text('评论'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '测试评论');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(find.text('请先在「我的」页配置登录凭证'), findsOneWidget);
    // 输入内容保留（没有发送成功也不清空，方便用户配置后再发）。
    expect(find.widgetWithText(TextField, '测试评论'), findsOneWidget);

    await _drainLogTimer(tester);
  });
}
