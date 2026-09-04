import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

/// 多一筆老婆的私人支出，驗私人資料只顯示自己的。
class WithWifePrivate extends EntriesNotifier {
  @override
  List<Entry> build() => [
        ...super.build(),
        Entry(
          id: 'e-wife-private',
          ledgerId: kLedgerId,
          kind: EntryKind.expense,
          scope: EntryScope.private,
          amount: 999,
          categoryId: 'c-fun',
          occurredOn: DateTime.now(),
          createdBy: kWifeId,
          note: '老婆的雞蛋秘密',
          lineItems: const [LineItem(id: 'li-w1', entryId: 'e-wife-private', name: '雞蛋禮盒', amount: 999)],
        ),
      ];
}

Future<ProviderContainer> pumpApp(WidgetTester tester, [ProviderContainer? container]) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final c = container ?? ProviderContainer();
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const AccountingApp()));
  await tester.pumpAndSettle();
  return c;
}

/// 只看搜尋結果列裡的文字（避開搜尋框、折線圖座標軸與底部 Tab）。
Finder inResults(String text) =>
    find.descendant(of: find.byKey(const Key('search-results')), matching: find.text(text));

Future<void> openSearch(WidgetTester tester, String query) async {
  await tester.tap(find.byTooltip('搜尋'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('search-field')), query);
  await tester.pumpAndSettle();
}

void main() {

  testWidgets('搜尋品項：命中細項並顯示所屬主筆備註', (tester) async {
    await pumpApp(tester);
    await openSearch(tester, '雞蛋');

    expect(inResults('雞蛋'), findsNWidgets(3));
    // li-1 89（全聯買菜）、li-6 189（Costco）、li-8 80（菜市場）
    expect(inResults('89'), findsOneWidget);
    expect(inResults('189'), findsOneWidget);
    expect(inResults('80'), findsOneWidget);
    expect(find.textContaining('全聯買菜'), findsWidgets);
    expect(find.textContaining('Costco'), findsWidgets);
    expect(find.textContaining('菜市場'), findsWidgets);
    // 同名 ≥2 筆 → 頂部價格折線卡
    expect(find.byType(SfCartesianChart), findsOneWidget);
    expect(find.text('雞蛋 價格變化'), findsOneWidget);
  });

  testWidgets('同名品項 ≥2 筆時顯示價格折線卡', (tester) async {
    await pumpApp(tester);
    await openSearch(tester, '雞蛋');
    expect(find.byType(SfCartesianChart), findsOneWidget);

    await tester.enterText(find.byKey(const Key('search-field')), '高麗菜');
    await tester.pumpAndSettle();
    expect(find.byType(SfCartesianChart), findsNothing);
  });

  testWidgets('備註命中自成一列、清單命中帶清單標籤', (tester) async {
    await pumpApp(tester);
    await openSearch(tester, '牛奶');
    expect(inResults('清單'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('search-field')), '房租');
    await tester.pumpAndSettle();
    expect(inResults('房租'), findsWidgets);
  });

  testWidgets('私人資料只顯示自己的', (tester) async {
    await pumpApp(tester, ProviderContainer(overrides: [entriesProvider.overrideWith(WithWifePrivate.new)]));
    await openSearch(tester, '雞蛋');
    expect(find.text('雞蛋禮盒'), findsNothing);
    expect(find.textContaining('老婆的雞蛋秘密'), findsNothing);
  });

  testWidgets('空字串顯示提示、無結果顯示空狀態', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('搜尋'));
    await tester.pumpAndSettle();
    expect(find.textContaining('輸入品項'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('search-field')), 'zzzz');
    await tester.pumpAndSettle();
    expect(find.textContaining('找不到'), findsOneWidget);
  });

  testWidgets('點結果進到主筆表單', (tester) async {
    await pumpApp(tester);
    await openSearch(tester, '高麗菜');
    await tester.tap(inResults('高麗菜'));
    await tester.pumpAndSettle();
    // 編輯＝單頁明細 hub（2026-09-03）。
    expect(find.byKey(const Key('edit-mode')), findsOneWidget);
    expect(find.text('明細'), findsOneWidget);
  });
}
