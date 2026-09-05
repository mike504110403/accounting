import 'package:accounting/domain/balance_math.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

import '../../support/fixtures.dart';

ProviderContainer containerFor(LedgerRepository repo) =>
    ProviderContainer(overrides: [ledgerRepositoryProvider.overrideWithValue(repo)]);

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

DateTime get _thisMonth => monthOf(DateTime.now());

/// 兩位成員各記一筆含「牛奶」細項的支出：v1.5 沒有私人範圍，兩筆都該搜得到。
List<Entry> milkByBothMembers() => [
      Entry(
        id: 'e-milk-mike',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        amount: 300,
        categoryId: 'c-food',
        occurredOn: DateTime(_thisMonth.year, _thisMonth.month, 3),
        createdBy: kMeId,
        note: 'Mike 的採買',
        payerId: kMeId,
        lineItems: const [LineItem(id: 'li-m1', entryId: 'e-milk-mike', name: '牛奶', amount: 95)],
      ),
      Entry(
        id: 'e-milk-wife',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        amount: 220,
        categoryId: 'c-food',
        occurredOn: DateTime(_thisMonth.year, _thisMonth.month, 8),
        createdBy: kWifeId,
        note: '老婆的採買',
        payerId: kWifeId,
        lineItems: const [LineItem(id: 'li-w1', entryId: 'e-milk-wife', name: '牛奶', amount: 110)],
      ),
    ];

void main() {
  // 驗收 6：v1.5 沒有 scope，兩個人記的都搜得到（v1.4 時老婆那筆若是私人就會被濾掉）。
  testWidgets('兩位成員各記一筆「牛奶」細項：兩筆都搜得到', (tester) async {
    await pumpApp(tester, containerFor(repoWith(entries: milkByBothMembers(), listItems: const [])));
    await openSearch(tester, '牛奶');

    expect(inResults('牛奶'), findsNWidgets(2));
    expect(inResults('95'), findsOneWidget);
    expect(inResults('110'), findsOneWidget);
    expect(find.textContaining('Mike 的採買'), findsWidgets);
    expect(find.textContaining('老婆的採買'), findsWidgets);
  });

  testWidgets('同名品項 ≥2 筆時顯示價格折線卡；只有 1 筆就不畫', (tester) async {
    await pumpApp(tester, containerFor(repoWith(entries: milkByBothMembers(), listItems: const [])));
    await openSearch(tester, '牛奶');
    expect(find.byType(SfCartesianChart), findsOneWidget);
    expect(find.text('牛奶 價格變化'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('search-field')), 'Mike 的採買');
    await tester.pumpAndSettle();
    expect(find.byType(SfCartesianChart), findsNothing);
  });

  testWidgets('搜尋品項：命中細項並顯示所屬主筆備註（波 1 假資料）', (tester) async {
    await pumpApp(tester);
    await openSearch(tester, '雞蛋');

    // 假資料本月「本月買菜」帶三列細項：雞蛋 89、牛奶 95、高麗菜 45。
    expect(inResults('雞蛋'), findsOneWidget);
    expect(inResults('89'), findsOneWidget);
    expect(find.textContaining('本月買菜'), findsWidgets);
  });

  testWidgets('備註命中自成一列、清單命中帶清單標籤', (tester) async {
    await pumpApp(tester);
    await openSearch(tester, '牛奶');
    // 假資料的購物清單有一項「牛奶」。
    expect(inResults('清單'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('search-field')), '本月買菜');
    await tester.pumpAndSettle();
    expect(inResults('本月買菜'), findsWidgets);
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

  testWidgets('點結果進到主筆明細', (tester) async {
    await pumpApp(tester);
    await openSearch(tester, '高麗菜');
    await tester.tap(inResults('高麗菜'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('edit-mode')), findsOneWidget);
    expect(find.text('明細'), findsOneWidget);
  });
}
