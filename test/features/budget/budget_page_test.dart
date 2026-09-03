import 'package:accounting/app/format.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/budget/budget_page.dart';
import 'package:accounting/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _ThrowingBudgetsNotifier extends BudgetsNotifier {
  @override
  void upsert(Budget b) => throw Exception('boom');
}

void main() {
  testWidgets('AccountingApp 根啟動點「預算」看到「食品」卡且顯示有效上限', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: AccountingApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('預算'));
    await tester.pumpAndSettle();

    expect(find.text('食品'), findsOneWidget);
    // 假資料：食品上月 5,500 花 6,200、rollover 開 → 本月有效 4,800。
    expect(find.textContaining('基礎 5,500／有效 4,800'), findsOneWidget);
  });

  testWidgets('月份標題左滑切下月、右滑切回上月（MonthTitle，取代箭頭）', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: BudgetPage())));
    await tester.pumpAndSettle();

    final now = DateTime.now();
    final thisMonth = DateTime(now.year, now.month, 1);
    final nextM = DateTime(thisMonth.year, thisMonth.month + 1, 1);
    expect(find.byKey(const Key('month-prev')), findsOneWidget); // 箭頭與滾輪並存
    expect(find.text(fmtMonth(thisMonth)), findsOneWidget);

    await tester.fling(find.byKey(const Key('month-title')), const Offset(-200, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text(fmtMonth(nextM)), findsOneWidget);

    await tester.fling(find.byKey(const Key('month-title')), const Offset(200, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text(fmtMonth(thisMonth)), findsOneWidget);
  });

  testWidgets('點月份標題開底部滾輪、按確定套用', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: BudgetPage())));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('month-title')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('month-picker-month')), findsOneWidget);

    await tester.tapAt(const Offset(200, 20)); // 點彈窗外即套用
    await tester.pumpAndSettle();

    final thisMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
    expect(find.text(fmtMonth(thisMonth)), findsOneWidget);
  });

  testWidgets('設定上限後卡片更新', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: BudgetPage())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('食品').first);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '9000');
    await tester.tap(find.text('儲存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('基礎 9,000'), findsOneWidget);
  });

  testWidgets('rollover 開關切換後卡片顯示「累計」徽章', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: BudgetPage())));
    await tester.pumpAndSettle();

    expect(find.text('累計'), findsNWidgets(2)); // 假資料：食品、日常用品預設開 rollover

    await tester.tap(find.text('餐飲').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.tap(find.text('儲存'));
    await tester.pumpAndSettle();

    expect(find.text('累計'), findsNWidgets(3));
  });

  testWidgets('無預算分類（娛樂）只切 rollover 存檔：不擋、不新增 budget、rollover 生效', (tester) async {
    // 娛樂排在分類清單較後面，預設測試視窗（800x600）看不到，放大視窗讓它建進 tree、可被 tap 到。
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const MaterialApp(home: BudgetPage())));
    await tester.pumpAndSettle();

    final budgetsBefore = container.read(budgetsProvider).length;
    expect(container.read(categoriesProvider).firstWhere((c) => c.id == 'c-fun').rollover, isFalse);

    await tester.tap(find.text('娛樂').first);
    await tester.pumpAndSettle();

    // c-fun 沒有任何 budget，金額欄應該是空的（不是非法值），不該擋存。
    final amountField = tester.widget<TextField>(find.byType(TextField).first);
    expect(amountField.controller?.text, isEmpty);

    await tester.tap(find.byType(Switch));
    await tester.tap(find.text('儲存'));
    await tester.pumpAndSettle();

    expect(find.text('請輸入有效金額'), findsNothing);
    expect(container.read(budgetsProvider).length, budgetsBefore); // 沒有新增 budget
    expect(container.read(categoriesProvider).firstWhere((c) => c.id == 'c-fun').rollover, isTrue);
  });

  testWidgets('上限儲存失敗顯示 SnackBar', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [budgetsProvider.overrideWith(() => _ThrowingBudgetsNotifier())],
        child: const MaterialApp(home: BudgetPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('食品').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '1234');
    await tester.tap(find.text('儲存'));
    await tester.pumpAndSettle();

    expect(find.text('儲存失敗，請重試'), findsOneWidget);
  });

  testWidgets('390px 不爆版（無 overflow）', (tester) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: BudgetPage())));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('深色主題渲染不炸', (tester) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6F6D), brightness: Brightness.dark)),
          home: const BudgetPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
