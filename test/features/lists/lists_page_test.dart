import 'package:accounting/app/format.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/lists/lists_page.dart';
import 'package:accounting/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _ThrowingEntriesAdd extends EntriesNotifier {
  @override
  void add(Entry e) => throw Exception('boom');
}

class _ThrowingListItemsAdd extends ListItemsNotifier {
  @override
  void add(ListItem i) => throw Exception('boom');
}

class _ThrowingListItemsRemove extends ListItemsNotifier {
  @override
  void remove(String id) => throw Exception('boom');
}

class _ThrowingListItemsUpdate extends ListItemsNotifier {
  @override
  void update(ListItem i) => throw Exception('boom');
}

/// 只有第二次 update 丟例外（第三次以後的呼叫，也就是補償迴圈的復原呼叫，會成功）——
/// 用來真的走到「部分成功後復原」那段補償路徑，並驗證復原確實把已完成的項目改回去。
/// 註：若改成「第二次以後永遠丟」（`>= 2`），補償迴圈自己的 update 呼叫也會被打中而被吞掉，
/// 復原就會失敗、酸奶會卡在已完成——那是另一個更極端的「連補償都救不回來」情境，不是這條測試要釘的行為。
class _ThrowingListItemsUpdateOnSecond extends ListItemsNotifier {
  int _n = 0;

  @override
  void update(ListItem i) {
    if (++_n == 2) throw Exception('boom');
    super.update(i);
  }
}

/// 固定 dueOn 測試用 fixture（避免依賴 mock_data 種子當下 DateTime.now() 的時刻）。
/// 用 constructor 注入而非頂層可變全域，避免測試間互相汙染。
class _FixedDueListItemsNotifier extends ListItemsNotifier {
  _FixedDueListItemsNotifier(this.items);
  final List<ListItem> items;

  @override
  List<ListItem> build() => items;
}

/// 手機寬度視窗（跟 stats_page_test.dart 的 phone() 同一慣例），用來自查 390px 不爆版。
Future<void> _phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpWithContainer(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ListsPage()),
    ),
  );
  await tester.pumpAndSettle();
}

/// 一般（無 override）情境的捷徑。
Future<ProviderContainer> _pumpListsPage(WidgetTester tester) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await _pumpWithContainer(tester, container);
  return container;
}

void main() {
  testWidgets('AccountingApp 根啟動點底部 Tab 進清單頁看到超市分組與酸奶', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: AccountingApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('清單'));
    await tester.pumpAndSettle();

    expect(find.text('超市'), findsOneWidget);
    expect(find.text('酸奶'), findsOneWidget);
  });

  testWidgets('單勾一項 → 底部 sheet 確認 → entriesProvider 新增一筆、該項 isDone', (tester) async {
    final container = await _pumpListsPage(tester);

    await tester.tap(find.widgetWithText(ListTile, '酸奶'));
    await tester.pumpAndSettle();
    expect(find.text('確認結帳'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await tester.pumpAndSettle();

    final entries = container.read(entriesProvider);
    final newEntry = entries.firstWhere((e) => e.note == '超市' && e.lineItems.length == 1 && e.lineItems.single.name == '酸奶');
    expect(newEntry.amount, 120);
    expect(newEntry.kind, EntryKind.expense);
    expect(newEntry.scope, EntryScope.shared);
    expect(newEntry.splitMethod, SplitMethod.common);

    final item = container.read(listItemsProvider).firstWhere((i) => i.id == 'l-2');
    expect(item.isDone, isTrue);
    expect(item.entryId, newEntry.id);

    final today = DateTime.now();
    expect(newEntry.occurredOn, DateTime(today.year, today.month, today.day));
  });

  testWidgets('單項結帳：只有一個金額欄，改金額 → entry.amount 用新值（無總計欄）', (tester) async {
    final container = await _pumpListsPage(tester);

    await tester.tap(find.widgetWithText(ListTile, '酸奶'));
    await tester.pumpAndSettle();

    // 單項結帳沒有「總計」欄，只有一個「金額」欄。
    expect(find.widgetWithText(TextField, '120'), findsOneWidget); // estimated 預填
    expect(find.text('總計'), findsNothing);

    await tester.enterText(find.byType(TextField).at(0), '150');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await tester.pumpAndSettle();

    final entries = container.read(entriesProvider);
    final newEntry = entries.firstWhere((e) => e.note == '超市' && e.lineItems.length == 1 && e.lineItems.single.name == '酸奶');
    expect(newEntry.amount, 150);
    expect(newEntry.lineItems.single.amount, 150);
  });

  testWidgets('多項結帳：總計唯讀自動加總、即時更新，改一項金額後總計文字與 entry.amount 都跟著變', (tester) async {
    final container = await _pumpListsPage(tester);

    await tester.longPress(find.widgetWithText(ListTile, '酸奶'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '麵包'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '完成'));
    await tester.pumpAndSettle();

    // 酸奶 120 + 麵包 80 = 200，總計唯讀顯示、沒有可編輯的總計欄位。
    expect(find.text('200 元'), findsOneWidget);

    // 改酸奶（第一個金額欄）從 120 → 300，總計應即時變成 380（=300+80）。
    await tester.enterText(find.byType(TextField).at(0), '300');
    await tester.pumpAndSettle();
    expect(find.text('380 元'), findsOneWidget);
    expect(find.text('200 元'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await tester.pumpAndSettle();

    final entries = container.read(entriesProvider);
    final newEntry = entries.firstWhere((e) => e.lineItems.map((l) => l.name).toSet().containsAll({'酸奶', '麵包'}));
    expect(newEntry.amount, 380);
    expect(newEntry.lineItems.firstWhere((l) => l.name == '酸奶').amount, 300);
    expect(newEntry.lineItems.firstWhere((l) => l.name == '麵包').amount, 80);
  });

  testWidgets('已完成折疊區展開後顯示項目、金額與日期', (tester) async {
    await _pumpListsPage(tester);

    await tester.tap(find.widgetWithText(ListTile, '酸奶'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await tester.pumpAndSettle();

    expect(find.text('已完成 1'), findsOneWidget);
    await tester.tap(find.text('已完成 1'));
    await tester.pumpAndSettle();

    final doneTile = find.widgetWithText(ListTile, '酸奶');
    expect(doneTile, findsOneWidget);
    expect(find.descendant(of: doneTile, matching: find.text('120 元')), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('長按進入多選、選酸奶＋麵包、完成 → 一筆支出 amount=200、lineItems 2 筆、兩項同 entryId', (tester) async {
    final container = await _pumpListsPage(tester);

    await tester.longPress(find.widgetWithText(ListTile, '酸奶'));
    await tester.pumpAndSettle();
    expect(find.text('已選 1 項'), findsOneWidget);

    await tester.tap(find.widgetWithText(ListTile, '麵包'));
    await tester.pumpAndSettle();
    expect(find.text('已選 2 項'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '完成'));
    await tester.pumpAndSettle();
    expect(find.text('確認結帳'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await tester.pumpAndSettle();

    final entries = container.read(entriesProvider);
    final newEntry = entries.firstWhere((e) => e.lineItems.map((l) => l.name).toSet().containsAll({'酸奶', '麵包'}));
    expect(newEntry.lineItems.length, 2);
    expect(newEntry.amount, 200);
    expect(newEntry.lineItems.map((l) => l.name).toSet(), {'酸奶', '麵包'});

    final items = container.read(listItemsProvider);
    final soymilk = items.firstWhere((i) => i.id == 'l-2');
    final bread = items.firstWhere((i) => i.id == 'l-3');
    expect(soymilk.isDone, isTrue);
    expect(bread.isDone, isTrue);
    expect(soymilk.entryId, newEntry.id);
    expect(bread.entryId, newEntry.id);

    final today = DateTime.now();
    expect(newEntry.occurredOn, DateTime(today.year, today.month, today.day));

    // 完成後退出多選模式。
    expect(find.text('清單'), findsOneWidget);
  });

  testWidgets('待辦到期日＝今天＋3 天（日期邊界，去掉時分秒）顯示「即將到期」', (tester) async {
    final today = DateTime.now();
    final dateOnly = DateTime(today.year, today.month, today.day);
    final farDueOn = dateOnly.add(const Duration(days: 4));
    final fixture = [
      ListItem(id: 't-1', ledgerId: kLedgerId, title: '繳管理費', assigneeId: kMeId, dueOn: dateOnly.add(const Duration(days: 3))),
      ListItem(id: 't-2', ledgerId: kLedgerId, title: '已過期任務', assigneeId: kMeId, dueOn: dateOnly.subtract(const Duration(days: 1))),
      ListItem(id: 't-3', ledgerId: kLedgerId, title: '還早任務', assigneeId: kMeId, dueOn: farDueOn),
    ];
    final container = ProviderContainer(overrides: [listItemsProvider.overrideWith(() => _FixedDueListItemsNotifier(fixture))]);
    addTearDown(container.dispose);
    await _pumpWithContainer(tester, container);

    await tester.tap(find.text('待辦'));
    await tester.pumpAndSettle();

    expect(find.text('繳管理費'), findsOneWidget);
    expect(find.text('即將到期'), findsOneWidget);
    expect(find.text('已過期'), findsOneWidget);
    expect(find.text('還早任務'), findsOneWidget);
    // normal 分支不換成標籤，直接顯示日期，釘住渲染。
    final farTile = find.widgetWithText(ListTile, '還早任務');
    expect(find.descendant(of: farTile, matching: find.text(fmtDate(farDueOn))), findsOneWidget);
  });

  testWidgets('新增購物項目後出現在指定店家分組', (tester) async {
    final container = await _pumpListsPage(tester);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('新增購物項目'), findsOneWidget);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '可頌');
    await tester.enterText(fields.at(1), '超市');
    await tester.enterText(fields.at(2), '65');

    await tester.tap(find.widgetWithText(FilledButton, '新增'));
    await tester.pumpAndSettle();

    final items = container.read(listItemsProvider);
    final added = items.firstWhere((i) => i.title == '可頌');
    expect(added.store, '超市');
    expect(added.estimated, 65);
    expect(find.text('可頌'), findsOneWidget);
  });

  testWidgets('新增待辦後出現在待辦分頁', (tester) async {
    final container = await _pumpListsPage(tester);

    await tester.tap(find.text('待辦'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('新增待辦'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '倒垃圾');
    await tester.tap(find.widgetWithText(FilledButton, '新增'));
    await tester.pumpAndSettle();

    expect(container.read(listItemsProvider).any((i) => i.title == '倒垃圾' && i.isTodo), isTrue);
    expect(find.text('倒垃圾'), findsOneWidget);
  });

  testWidgets('待辦勾選 → doneAt 寫入、checkbox 打勾', (tester) async {
    final container = await _pumpListsPage(tester);

    await tester.tap(find.text('待辦'));
    await tester.pumpAndSettle();

    final tile = find.widgetWithText(ListTile, '繳管理費');
    final checkbox = find.descendant(of: tile, matching: find.byType(Checkbox));
    await tester.tap(checkbox);
    await tester.pumpAndSettle();

    final item = container.read(listItemsProvider).firstWhere((i) => i.id == 'l-6');
    expect(item.isDone, isTrue);
  });

  testWidgets('滑動刪除確認後從清單移除', (tester) async {
    final container = await _pumpListsPage(tester);

    await tester.drag(find.byKey(const ValueKey('dismiss-shopping-l-1')), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('確定刪除「衛生紙」？'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '刪除'));
    await tester.pumpAndSettle();

    expect(container.read(listItemsProvider).any((i) => i.id == 'l-1'), isFalse);
    expect(find.text('衛生紙'), findsNothing);
  });

  testWidgets('entry 寫入失敗 → SnackBar、entries 沒多、項目沒被標完成', (tester) async {
    // 寫入順序是「先 add entry、再逐項 update」，add 一失敗就整個結帳沒發生：
    // entries 不變，項目也還沒被摸到。
    final container = ProviderContainer(overrides: [entriesProvider.overrideWith(_ThrowingEntriesAdd.new)]);
    addTearDown(container.dispose);
    final entriesBefore = container.read(entriesProvider).length;
    await _pumpWithContainer(tester, container);

    await tester.tap(find.widgetWithText(ListTile, '酸奶'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await tester.pumpAndSettle();

    expect(find.text('結帳失敗，請稍後再試'), findsOneWidget);
    expect(container.read(entriesProvider).length, entriesBefore);
    final item = container.read(listItemsProvider).firstWhere((i) => i.id == 'l-2');
    expect(item.isDone, isFalse);
  });

  testWidgets('結帳時項目更新失敗 → SnackBar、補償刪掉孤兒 entry、項目沒被標完成', (tester) async {
    final container = ProviderContainer(overrides: [listItemsProvider.overrideWith(_ThrowingListItemsUpdate.new)]);
    addTearDown(container.dispose);
    final entriesBefore = container.read(entriesProvider).length;
    await _pumpWithContainer(tester, container);

    await tester.tap(find.widgetWithText(ListTile, '酸奶'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await tester.pumpAndSettle();

    expect(find.text('結帳失敗，請稍後再試'), findsOneWidget);
    expect(container.read(entriesProvider).length, entriesBefore);
    expect(container.read(entriesProvider).any((e) => e.note == '超市' && e.lineItems.any((l) => l.name == '酸奶')), isFalse);
    final item = container.read(listItemsProvider).firstWhere((i) => i.id == 'l-2');
    expect(item.isDone, isFalse);
  });

  testWidgets('多項結帳第二項才更新失敗 → 真的走到復原：兩項都沒 done、entries 不變、SnackBar', (tester) async {
    final container = ProviderContainer(overrides: [listItemsProvider.overrideWith(_ThrowingListItemsUpdateOnSecond.new)]);
    addTearDown(container.dispose);
    final entriesBefore = container.read(entriesProvider).length;
    await _pumpWithContainer(tester, container);

    await tester.longPress(find.widgetWithText(ListTile, '酸奶'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '麵包'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '完成'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await tester.pumpAndSettle();

    expect(find.text('結帳失敗，請稍後再試'), findsOneWidget);
    expect(container.read(entriesProvider).length, entriesBefore);
    final items = container.read(listItemsProvider);
    expect(items.firstWhere((i) => i.id == 'l-2').isDone, isFalse); // 酸奶：第一次 update 成功後被復原
    expect(items.firstWhere((i) => i.id == 'l-3').isDone, isFalse); // 麵包：第二次 update 本來就丟例外
  });

  testWidgets('金額欄清空 → 確認鈕 disabled、entries 不變', (tester) async {
    final container = await _pumpListsPage(tester);
    final entriesBefore = container.read(entriesProvider).length;

    await tester.tap(find.widgetWithText(ListTile, '酸奶'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), '');
    await tester.pumpAndSettle();

    expect(find.text('請輸入金額'), findsOneWidget);
    final confirmButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '確認'));
    expect(confirmButton.onPressed, isNull);

    // disabled 狀態下點擊不會有任何效果。
    await tester.tap(find.widgetWithText(FilledButton, '確認'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(container.read(entriesProvider).length, entriesBefore);
  });

  testWidgets('新增購物項目失敗顯示 SnackBar', (tester) async {
    final container = ProviderContainer(overrides: [listItemsProvider.overrideWith(_ThrowingListItemsAdd.new)]);
    addTearDown(container.dispose);
    await _pumpWithContainer(tester, container);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '可頌');
    await tester.tap(find.widgetWithText(FilledButton, '新增'));
    await tester.pumpAndSettle();

    expect(find.text('新增失敗，請稍後再試'), findsOneWidget);
  });

  testWidgets('刪除項目失敗顯示 SnackBar', (tester) async {
    final container = ProviderContainer(overrides: [listItemsProvider.overrideWith(_ThrowingListItemsRemove.new)]);
    addTearDown(container.dispose);
    await _pumpWithContainer(tester, container);

    await tester.drag(find.byKey(const ValueKey('dismiss-shopping-l-1')), const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '刪除'));
    await tester.pumpAndSettle();

    expect(find.text('刪除失敗，請稍後再試'), findsOneWidget);
    expect(container.read(listItemsProvider).any((i) => i.id == 'l-1'), isTrue);
  });

  testWidgets('待辦勾選失敗顯示 SnackBar', (tester) async {
    final container = ProviderContainer(overrides: [listItemsProvider.overrideWith(_ThrowingListItemsUpdate.new)]);
    addTearDown(container.dispose);
    await _pumpWithContainer(tester, container);

    await tester.tap(find.text('待辦'));
    await tester.pumpAndSettle();

    final tile = find.widgetWithText(ListTile, '繳管理費');
    final checkbox = find.descendant(of: tile, matching: find.byType(Checkbox));
    await tester.tap(checkbox);
    await tester.pumpAndSettle();

    expect(find.text('更新失敗，請稍後再試'), findsOneWidget);
  });

  testWidgets('資訊密度精簡：購物列去 Chip、分類與負責人擇一顯示、新增 sheet 標籤在左去說明文字', (tester) async {
    await _pumpListsPage(tester);

    // 購物列不再用 Chip；同一列的分類／負責人小圖示最多一個。
    expect(find.byType(Chip), findsNothing);

    final soymilkTile = find.widgetWithText(ListTile, '酸奶'); // 有指派負責人（kWifeId）
    expect(find.descendant(of: soymilkTile, matching: find.byType(CircleAvatar)), findsOneWidget);
    expect(find.descendant(of: soymilkTile, matching: find.byType(Icon)), findsNothing); // 有負責人時同列不再顯示分類 Icon

    final breadTile = find.widgetWithText(ListTile, '麵包'); // 沒指派，退回分類小圖示
    expect(find.descendant(of: breadTile, matching: find.byType(CircleAvatar)), findsNothing);
    expect(find.descendant(of: breadTile, matching: find.byType(Icon)), findsOneWidget);

    // 新增購物項目 sheet：標籤在左（純文字，不是浮動 labelText），去掉「（可留空）」說明文字。
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('店家'), findsOneWidget);
    expect(find.text('店家（可留空）'), findsNothing);
    Navigator.of(tester.element(find.text('新增購物項目'))).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('390px 不爆版（無 overflow）：購物清單、待辦、結帳 sheet、新增 sheet 都要過', (tester) async {
    await _phone(tester);
    await _pumpListsPage(tester);
    expect(tester.takeException(), isNull);

    // 單項結帳路徑（只有一個金額欄、無總計那排）。
    await tester.tap(find.widgetWithText(ListTile, '牛奶'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 購物清單：長按多選也要過。
    await tester.longPress(find.widgetWithText(ListTile, '酸奶'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(ListTile, '麵包'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.widgetWithText(TextButton, '完成'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull); // 多項結帳 sheet（有唯讀總計那排）

    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 已完成折疊區展開。
    await tester.tap(find.textContaining('已完成'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 新增購物項目 sheet。
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    Navigator.of(tester.element(find.text('新增購物項目'))).pop();
    await tester.pumpAndSettle();

    // 待辦分頁與新增待辦 sheet。
    await tester.tap(find.text('待辦'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('日期／到期日列點擊目標 ≥ 44px、點標籤（不只右邊值）也能開日期選擇器', (tester) async {
    await _pumpListsPage(tester);

    // 結帳 sheet 的日期列。
    await tester.tap(find.widgetWithText(ListTile, '酸奶'));
    await tester.pumpAndSettle();
    final checkoutDateRow = find.byKey(const Key('checkout-date-row'));
    expect(checkoutDateRow, findsOneWidget);
    expect(tester.getSize(checkoutDateRow).height, greaterThanOrEqualTo(44.0));

    // 點「日期」標籤本身（列最左邊），不是只有右邊的日期值可以點。
    await tester.tap(find.descendant(of: checkoutDateRow, matching: find.text('日期')));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    Navigator.of(tester.element(find.byType(DatePickerDialog))).pop();
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('確認結帳'))).pop(); // 關掉結帳 sheet
    await tester.pumpAndSettle();

    // 新增待辦 sheet 的到期日列，同一套元件、同一個規則。
    await tester.tap(find.text('待辦'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    final todoDueRow = find.byKey(const Key('todo-due-row'));
    expect(todoDueRow, findsOneWidget);
    expect(tester.getSize(todoDueRow).height, greaterThanOrEqualTo(44.0));

    await tester.tap(find.descendant(of: todoDueRow, matching: find.text('到期日')));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    Navigator.of(tester.element(find.byType(DatePickerDialog))).pop();
    await tester.pumpAndSettle();
  });
}
