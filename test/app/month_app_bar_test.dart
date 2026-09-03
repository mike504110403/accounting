import 'package:accounting/app/month_app_bar.dart';
import 'package:accounting/app/view_mode_toggle.dart';
import 'package:accounting/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _page({Widget? leading, List<Widget>? actions}) => MaterialApp(
      home: Scaffold(
        appBar: MonthAppBar(
          month: DateTime(2026, 9, 1),
          onMonthChanged: (_) {},
          view: ViewMode.family,
          onViewChanged: (_) {},
          leading: leading,
          actions: actions,
        ),
      ),
    );

void main() {
  testWidgets('有無 leading／actions，月份標題與切換列的位置完全相同', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();
    final t1 = tester.getRect(find.byKey(const Key('month-title')));
    final v1 = tester.getRect(find.byType(ViewModeToggle));

    await tester.pumpWidget(_page(
      leading: IconButton(icon: const Icon(Icons.search), onPressed: () {}),
      actions: [IconButton(icon: const Icon(Icons.settings), onPressed: () {})],
    ));
    await tester.pumpAndSettle();
    final t2 = tester.getRect(find.byKey(const Key('month-title')));
    final v2 = tester.getRect(find.byType(ViewModeToggle));

    expect(t2, t1);
    expect(v2, v1);
    expect(v1.height, MonthAppBar.toggleHeight);
  });
}
