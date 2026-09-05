import 'package:accounting/app/month_app_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _page({Widget? leading, List<Widget>? actions}) => MaterialApp(
      home: Scaffold(
        appBar: MonthAppBar(
          month: DateTime(2026, 9, 1),
          onMonthChanged: (_) {},
          leading: leading,
          actions: actions,
        ),
      ),
    );

void main() {
  testWidgets('有無 leading／actions，月份標題位置完全相同', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();
    final t1 = tester.getRect(find.byKey(const Key('month-title')));

    await tester.pumpWidget(_page(
      leading: IconButton(icon: const Icon(Icons.search), onPressed: () {}),
      actions: [IconButton(icon: const Icon(Icons.settings), onPressed: () {})],
    ));
    await tester.pumpAndSettle();
    final t2 = tester.getRect(find.byKey(const Key('month-title')));

    expect(t2, t1);
  });

  testWidgets('v1.5：沒有視角切換，高度回到單層 AppBar', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    // 視角切換的 key 是 v1.4 的 `view-mode-toggle`；v1.5（ADR-0009）整條移除。
    expect(find.byKey(const Key('view-mode-toggle')), findsNothing);
    expect(find.text('家庭'), findsNothing);
    expect(find.text('個人'), findsNothing);

    final bar = tester.widget<MonthAppBar>(find.byType(MonthAppBar));
    expect(bar.preferredSize.height, kToolbarHeight,
        reason: '少了下面那層切換，preferredSize 要跟著縮回來，否則頁面頂部留一條空白');
    expect(tester.getSize(find.byType(AppBar)).height, kToolbarHeight);
  });
}
