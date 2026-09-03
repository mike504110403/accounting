import 'package:accounting/app/month_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(ValueChanged<DateTime> onChanged, {DateTime? month}) => MaterialApp(
      home: Scaffold(appBar: AppBar(title: MonthTitle(month: month ?? DateTime(2026, 9, 1), onChanged: onChanged))),
    );

void main() {
  _arrows();
  testWidgets('點標題開彈窗：年份與月份是兩個獨立滾輪', (tester) async {
    await tester.pumpWidget(_host((_) {}));
    await tester.tap(find.byKey(const Key('month-title')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('month-picker-year')), findsOneWidget);
    expect(find.byKey(const Key('month-picker-month')), findsOneWidget);
    expect(find.byType(CupertinoPicker), findsNWidgets(2));
  });

  testWidgets('滾動月份後點彈窗外：關閉並套用', (tester) async {
    DateTime? got;
    await tester.pumpWidget(_host((m) => got = m));
    await tester.tap(find.byKey(const Key('month-title')));
    await tester.pumpAndSettle();
    // 月份滾輪往上捲一格（9 → 10）
    await tester.drag(find.byKey(const Key('month-picker-month')), const Offset(0, -40));
    await tester.pumpAndSettle();
    // 點彈窗外（畫面最上方）
    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoPicker), findsNothing);
    expect(got, DateTime(2026, 10, 1));
  });

  testWidgets('沒動滾輪就點外面：不觸發 onChanged', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_host((_) => calls++));
    await tester.tap(find.byKey(const Key('month-title')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    expect(calls, 0);
  });

  testWidgets('「本月」快捷回到當月', (tester) async {
    DateTime? got;
    await tester.pumpWidget(_host((m) => got = m, month: DateTime(2020, 1, 1)));
    await tester.tap(find.byKey(const Key('month-title')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('month-picker-today')));
    await tester.pumpAndSettle();
    final now = DateTime.now();
    expect(got, DateTime(now.year, now.month, 1));
  });

  testWidgets('左滑切下月、右滑切上月', (tester) async {
    DateTime? got;
    await tester.pumpWidget(_host((m) => got = m));
    await tester.fling(find.byKey(const Key('month-title')), const Offset(-200, 0), 1000);
    await tester.pumpAndSettle();
    expect(got, DateTime(2026, 10, 1));
    await tester.fling(find.byKey(const Key('month-title')), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();
    expect(got, DateTime(2026, 8, 1));
  });
}

void _arrows() {
  testWidgets('左右箭頭快速切月', (tester) async {
    DateTime? got;
    await tester.pumpWidget(_host((m) => got = m));
    await tester.tap(find.byKey(const Key('month-next')));
    await tester.pumpAndSettle();
    expect(got, DateTime(2026, 10, 1));
    await tester.tap(find.byKey(const Key('month-prev')));
    await tester.pumpAndSettle();
    expect(got, DateTime(2026, 8, 1));
  });
}
