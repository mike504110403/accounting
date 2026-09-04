import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/app/category_wheel.dart';
import 'package:accounting/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// 只有一筆已結帳的支出。
List<Entry> settledOnlyEntries() => [
      Entry(
        id: 'e-locked',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 1000,
        categoryId: 'c-food',
        occurredOn: DateTime.now(),
        createdBy: kMeId,
        note: '已結帳的買菜',
        payerId: kMeId,
        splitMethod: SplitMethod.equal,
        settledState: SettledState.settled,
        splits: const [
          EntrySplit(entryId: 'e-locked', memberId: kMeId, share: 500),
          EntrySplit(entryId: 'e-locked', memberId: kWifeId, share: 500),
        ],
      ),
    ];

/// 只有一筆可刪的支出。
List<Entry> oneOpenEntry() => [
      Entry(
        id: 'e-open',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 300,
        categoryId: 'c-food',
        occurredOn: DateTime.now(),
        createdBy: kMeId,
        note: '可刪的買菜',
      ),
    ];

/// 一筆已結帳、用「金額」分攤且份額帶小數的支出：
/// 手填欄位只能顯示整數（284），沒有防禦層就會把 283.5 覆寫掉或被合計檢查擋存。
List<Entry> settledAmountSplitEntries() => [
      Entry(
        id: 'e-amt',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 567,
        categoryId: 'c-food',
        occurredOn: DateTime.now(),
        createdBy: kMeId,
        note: '已結帳的金額分攤',
        payerId: kMeId,
        splitMethod: SplitMethod.amount,
        settledState: SettledState.settled,
        splits: const [
          EntrySplit(entryId: 'e-amt', memberId: kMeId, share: 283.5),
          EntrySplit(entryId: 'e-amt', memberId: kWifeId, share: 283.5),
        ],
      ),
    ];

/// 一筆已結帳、帶一列細項的支出（細項在 settled 下仍可改，ADR-0002）。
List<Entry> settledWithLineItems() => [
      Entry(
        id: 'e-settled-li',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 1000,
        categoryId: 'c-food',
        occurredOn: DateTime.now(),
        createdBy: kMeId,
        note: '已結帳帶細項',
        payerId: kMeId,
        splitMethod: SplitMethod.equal,
        settledState: SettledState.settled,
        splits: const [
          EntrySplit(entryId: 'e-settled-li', memberId: kMeId, share: 500),
          EntrySplit(entryId: 'e-settled-li', memberId: kWifeId, share: 500),
        ],
        lineItems: const [LineItem(id: 'li-old', entryId: 'e-settled-li', name: '打錯的細項', amount: 1000, sort: 0)],
      ),
    ];

/// 一筆 70/30 比例分攤的支出，用來驗編輯時反推百分比。
List<Entry> ratioEntry() => [
      Entry(
        id: 'e-ratio',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 1000,
        categoryId: 'c-food',
        occurredOn: DateTime.now(),
        createdBy: kMeId,
        note: '比例筆',
        payerId: kMeId,
        splitMethod: SplitMethod.ratio,
        splits: const [
          EntrySplit(entryId: 'e-ratio', memberId: kMeId, share: 700),
          EntrySplit(entryId: 'e-ratio', memberId: kWifeId, share: 300),
        ],
      ),
    ];

/// 一筆結算中的支出（settling 期間金額同樣鎖定）。
List<Entry> settlingEntries() => [
      Entry(
        id: 'e-settling',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 800,
        categoryId: 'c-food',
        occurredOn: DateTime.now(),
        createdBy: kMeId,
        note: '結算中的買菜',
        payerId: kMeId,
        splitMethod: SplitMethod.equal,
        settledState: SettledState.settling,
        splits: const [
          EntrySplit(entryId: 'e-settling', memberId: kMeId, share: 400),
          EntrySplit(entryId: 'e-settling', memberId: kWifeId, share: 400),
        ],
      ),
    ];

/// 本月食品有撥款（3000）、交通有撥款（1000）；住房、餐飲本月無撥款——資金來源預設測試用固定 fixture。
List<BudgetAllocation> foodAndTransportAllocated() {
  final now = DateTime.now();
  final m = DateTime(now.year, now.month, 1);
  return [
    BudgetAllocation(id: 'a-1', ledgerId: kLedgerId, categoryId: 'c-food', amount: 3000, occurredOn: m, createdBy: kMeId),
    BudgetAllocation(id: 'a-2', ledgerId: kLedgerId, categoryId: 'c-transport', amount: 1000, occurredOn: m, createdBy: kMeId),
  ];
}

/// 一筆已存在的共同錢包食品支出（funding=budget），供編輯載入測試用。
List<Entry> budgetFundedEntry() => [
      Entry(
        id: 'e-budget',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 500,
        categoryId: 'c-food',
        occurredOn: DateTime.now(),
        createdBy: kMeId,
        note: '預算買菜',
        splitMethod: SplitMethod.common,
        funding: Funding.budget,
      ),
    ];

/// 一筆既有的代墊食品支出（funding 恆 balance，不變式逼出來的，不是使用者選的），
/// 供「編輯代墊筆→切回共同錢包」測試用。
List<Entry> advancedFoodEntry() => [
      Entry(
        id: 'e-advanced-food',
        ledgerId: kLedgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 500,
        categoryId: 'c-food',
        occurredOn: DateTime.now(),
        createdBy: kMeId,
        note: '代墊買菜',
        payerId: kMeId,
        splitMethod: SplitMethod.equal,
        splits: const [
          EntrySplit(entryId: 'e-advanced-food', memberId: kMeId, share: 250),
          EntrySplit(entryId: 'e-advanced-food', memberId: kWifeId, share: 250),
        ],
      ),
    ];

/// 把資料層換成指定內容的記憶體 repository（Notifier 的初值與寫入都吃它）。
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


// ── 步驟精靈導航（2026-09-03：表單改一次一步）─────────────────────────────
// 各互動 key 落在哪一步；helper 先導航到該步再操作，測試本文不用自己管步驟。
const _stepOfKeyPrefix = <String, int>{
  // 四關版（2026-09-03）：0 類型分類金額、1 日期備註細項、2 進階、3 確認。
  'category-wheel': 0,
  'amount-field': 0,
  'date-button': 1,
  'note-field': 1,
  'lineitem-': 1,
  'li-name-': 1,
  'li-amount-': 1,
  'scope-': 2,
  'payer-': 2,
  'funding-': 2,
  'split-': 2,
  'ratio-field-': 2,
  'manual-field-': 2,
  'ratio-': 2,
  'manual-': 2,
  'adjustment-switch': 2,
  'save-button': 3,
};

int? _stepFor(String key) {
  for (final e in _stepOfKeyPrefix.entries) {
    if (key == e.key || key.startsWith(e.key)) return e.value;
  }
  return null;
}

int? currentFormStep(WidgetTester tester) {
  for (var i = 0; i <= 3; i++) {
    if (tester.any(find.byKey(ValueKey('form-step-$i')))) return i;
  }
  return null; // 不在表單頁
}

// 編輯 hub（2026-09-03）：編輯既有帳目＝單頁明細，各欄位點列開彈窗；步驟導航只屬於新增精靈。
// 編輯 hub 走「key → 欄位列」：同一關的欄位在 hub 是不同列。
const _editRowOfKeyPrefix = <String, String>{
  'category-': 'edit-row-category',
  'amount-field': 'edit-row-amount',
  'date-button': 'date-button',
  'note-field': 'edit-row-note',
  'lineitem-': 'edit-row-lines',
  'li-name-': 'edit-row-lines',
  'li-amount-': 'edit-row-lines',
  'scope-': 'edit-row-advanced',
  'payer-': 'edit-row-advanced',
  'funding-': 'edit-row-advanced',
  'split-': 'edit-row-advanced',
  'ratio-': 'edit-row-advanced',
  'manual-': 'edit-row-advanced',
  'adjustment-switch': 'edit-row-advanced',
};

String? _editRowFor(String key) {
  for (final e in _editRowOfKeyPrefix.entries) {
    if (key == e.key || key.startsWith(e.key)) return e.value;
  }
  return null;
}

bool _inEditHub(WidgetTester tester) => tester.any(find.byKey(const Key('edit-mode')));

Future<void> _closeFieldSheet(WidgetTester tester) async {
  if (tester.any(find.byKey(const Key('field-done')))) {
    await tester.tap(find.byKey(const Key('field-done')));
    await tester.pumpAndSettle();
  }
}

Future<void> _openEditRow(WidgetTester tester, String row) async {
  await _closeFieldSheet(tester);
  await tester.ensureVisible(find.byKey(Key(row)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key(row)));
  await tester.pumpAndSettle();
}

Future<void> goToStep(WidgetTester tester, int target) async {
  if (_inEditHub(tester)) {
    // 編輯 hub 沒有步驟：只支援「回 hub」（關彈窗）；欄位導航走 _prepareFor 的 key 對映。
    await _closeFieldSheet(tester);
    return;
  }
  var cur = currentFormStep(tester);
  if (cur == null) fail('不在表單步驟頁上，無法導航到步驟 $target');
  var guard = 0;
  while (cur != target) {
    final key = cur! < target ? 'form-next-button' : 'form-back-button';
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
    cur = currentFormStep(tester);
    if (++guard > 12) fail('步驟導航沒有收斂（target=$target, cur=$cur）');
  }
}

/// 目標 key 已在畫面（彈窗開著／已在該步）就不動，否則導航／開對應彈窗。
Future<void> _prepareFor(WidgetTester tester, String key) async {
  final step = _stepFor(key);
  if (step == null) return;
  if (_inEditHub(tester)) {
    if (key == 'save-button') {
      await _closeFieldSheet(tester);
      return;
    }
    if (tester.any(find.byKey(Key(key)))) return; // 彈窗已開
    final row = _editRowFor(key);
    if (row == null) return;
    await _openEditRow(tester, row);
    return;
  }
  await goToStep(tester, step);
}

/// 分類改橫向循環選擇器（2026-09-04）：由目前選中往目標拖整數格（單格寬＝可視寬/5）。
Future<void> selectCategory(WidgetTester tester, String id) async {
  await _prepareFor(tester, 'category-wheel');
  final wheelF = find.byKey(const Key('category-wheel'));
  await tester.ensureVisible(wheelF);
  await tester.pumpAndSettle();
  final wheel = tester.widget<CategoryWheel>(wheelF);
  final ids = [for (final c in wheel.categories) c.id];
  final cur = ids.indexOf(wheel.selectedId ?? ids.first).clamp(0, ids.length - 1);
  final target = ids.indexOf(id);
  if (target < 0) fail('分類 $id 不在選擇器裡: $ids');
  final extent = tester.getSize(wheelF).width / CategoryWheel.visibleCount;
  await tester.drag(wheelF, Offset(-(target - cur) * extent, 0));
  await tester.pumpAndSettle();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  if (key == 'advanced-tile') {
    // 舊版是展開摺疊區；步驟版＝走到進階關／編輯 hub 開進階彈窗。
    if (_inEditHub(tester)) {
      if (!tester.any(find.byKey(const Key('scope-shared')))) {
        await _openEditRow(tester, 'edit-row-advanced');
      }
    } else {
      await goToStep(tester, 2);
    }
    return;
  }
  if (currentFormStep(tester) != null || _inEditHub(tester)) await _prepareFor(tester, key);
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> fillKey(WidgetTester tester, String key, String text) async {
  if (currentFormStep(tester) != null || _inEditHub(tester)) await _prepareFor(tester, key);
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.enterText(f, text);
  await tester.pumpAndSettle();
}

Future<void> openNewForm(WidgetTester tester) async {
  await tester.tap(find.text('新增'));
  await tester.pumpAndSettle();
}

/// 透過 `_pickDate` 打開的 [showDatePicker] 選日期：直接呼叫 [CalendarDatePicker.onDateChanged]
/// 這個公開回呼（等同使用者在日曆上點了那天），再按「OK」確認，不用在月曆格線裡逐格點擊翻月。
/// 本專案沒有配 `flutter_localizations`，Material 預設英文文案，確認鈕文字是 'OK'。
Future<void> pickDate(WidgetTester tester, DateTime date) async {
  await tapKey(tester, 'date-button');
  final picker = tester.widget<CalendarDatePicker>(find.byType(CalendarDatePicker));
  picker.onDateChanged(date);
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

void main() {

  testWidgets('新增支出：均分 567 → 283.5／283.5，entriesProvider 多一筆', (tester) async {
    final c = await pumpApp(tester);
    final before = c.read(entriesProvider).length;

    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '567');
    await selectCategory(tester, 'c-food');
    await fillKey(tester, 'note-field', '測試買菜');
    await tapKey(tester, 'advanced-tile');
    await tapKey(tester, 'payer-$kMeId');
    await tapKey(tester, 'split-equal');
    await tapKey(tester, 'save-button');

    final entries = c.read(entriesProvider);
    expect(entries.length, before + 1);
    final e = entries.last;
    expect(e.amount, 567);
    expect(e.note, '測試買菜');
    expect(e.categoryId, 'c-food');
    expect(e.kind, EntryKind.expense);
    expect(e.payerId, kMeId);
    expect(e.splitMethod, SplitMethod.equal);
    expect(e.splits.length, 2);
    expect(e.splits.map((s) => s.share).toList(), [283.5, 283.5]);
  });

  testWidgets('細項可加，差額只提示不擋存', (tester) async {
    final c = await pumpApp(tester);
    final before = c.read(entriesProvider).length;

    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '500');
    await selectCategory(tester, 'c-food');
    await tapKey(tester, 'lineitem-add');
    await fillKey(tester, 'li-name-0', '雞蛋');
    await fillKey(tester, 'li-amount-0', '89');
    expect(find.textContaining('合計'), findsOneWidget);
    await tapKey(tester, 'save-button');

    final entries = c.read(entriesProvider);
    expect(entries.length, before + 1);
    expect(entries.last.lineItems.single.name, '雞蛋');
    expect(entries.last.lineItems.single.amount, 89);
  });

  testWidgets('比例逐筆可調：改成 70/30 存檔 → splits 396.9／170.1', (tester) async {
    final c = await pumpApp(tester);
    final before = c.read(entriesProvider).length;

    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '567');
    await selectCategory(tester, 'c-food');
    await tapKey(tester, 'advanced-tile');
    await tapKey(tester, 'payer-$kMeId');
    await tapKey(tester, 'split-ratio');

    // 預設帶入帳本 default_ratio 50/50
    expect(tester.widget<TextField>(find.byKey(const Key('ratio-$kMeId'))).controller!.text, '50');
    expect(tester.widget<TextField>(find.byKey(const Key('ratio-$kWifeId'))).controller!.text, '50');

    await fillKey(tester, 'ratio-$kMeId', '70');
    await fillKey(tester, 'ratio-$kWifeId', '30');
    await tapKey(tester, 'save-button');

    final entries = c.read(entriesProvider);
    expect(entries.length, before + 1);
    final e = entries.last;
    expect(e.splitMethod, SplitMethod.ratio);
    expect(e.splits.map((s) => s.share).toList(), [396.9, 170.1]);
  });

  testWidgets('比例合計不是 100 → 擋存並提示', (tester) async {
    final c = await pumpApp(tester);
    final before = c.read(entriesProvider).length;

    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '500');
    await selectCategory(tester, 'c-food');
    await tapKey(tester, 'advanced-tile');
    await tapKey(tester, 'payer-$kMeId');
    await tapKey(tester, 'split-ratio');
    await fillKey(tester, 'ratio-$kMeId', '70');
    await fillKey(tester, 'ratio-$kWifeId', '20');
    await tapKey(tester, 'save-button');

    expect(find.textContaining('比例合計需為 100%'), findsOneWidget);
    expect(c.read(entriesProvider).length, before);
  });

  testWidgets('編輯既有比例筆：從 splits 反推百分比帶入', (tester) async {
    await pumpApp(tester, containerFor(repoWith(entries: ratioEntry())));
    await tester.tap(find.text('比例筆'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'enter-edit'); // 點列表＝唯讀明細，進編輯要按鉛筆（2026-09-04）
    await tapKey(tester, 'advanced-tile');

    expect(tester.widget<TextField>(find.byKey(const Key('ratio-$kMeId'))).controller!.text, '70');
    expect(tester.widget<TextField>(find.byKey(const Key('ratio-$kWifeId'))).controller!.text, '30');
  });

  testWidgets('390×844：新增表單不展開進階時一頁看完、不爆版', (tester) async {
    await pumpApp(tester);
    await openNewForm(tester);
    // 金額 0 擋下一步：先確認停用，填了才走關。
    expect(tester.widget<FilledButton>(find.byKey(const Key('form-next-button'))).onPressed, isNull);
    await fillKey(tester, 'amount-field', '100');

    // 步驟精靈：逐關走完，每一關都在視窗內、無 overflow；最後一關儲存鈕可見。
    for (var i = 0; i <= 2; i++) {
      expect(currentFormStep(tester), i);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('form-next-button')));
      await tester.pumpAndSettle();
    }
    expect(currentFormStep(tester), 3);
    expect(tester.getBottomRight(find.byKey(const Key('save-button'))).dy, lessThanOrEqualTo(844));
    expect(tester.takeException(), isNull);
  });

  testWidgets('金額分攤合計不等於主筆 → 擋存並提示', (tester) async {
    final c = await pumpApp(tester);
    final before = c.read(entriesProvider).length;

    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '500');
    await selectCategory(tester, 'c-food');
    await tapKey(tester, 'advanced-tile');
    await tapKey(tester, 'payer-$kMeId');
    await tapKey(tester, 'split-amount');
    await fillKey(tester, 'manual-$kMeId', '300');
    await fillKey(tester, 'manual-$kWifeId', '100');
    await tapKey(tester, 'save-button');

    expect(find.textContaining('分攤金額合計'), findsOneWidget);
    expect(c.read(entriesProvider).length, before);
  });

  testWidgets('已結帳：金額欄 disabled 並顯示鎖定說明', (tester) async {
    await pumpApp(tester, containerFor(repoWith(entries: settledOnlyEntries())));
    await tester.tap(find.text('已結帳的買菜'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'enter-edit'); // 點列表＝唯讀明細，進編輯要按鉛筆（2026-09-04）
    await _prepareFor(tester, 'amount-field');

    final amount = tester.widget<TextField>(find.byKey(const Key('amount-field')));
    expect(amount.enabled, isFalse);
    expect(find.textContaining('已結帳：金額與分攤鎖定'), findsOneWidget);
    expect(find.byKey(const Key('entry-menu')), findsNothing);
  });

  testWidgets('已結帳：付款來源／分攤／範圍全部 disabled，存檔不動這些欄位', (tester) async {
    final c = await pumpApp(tester, containerFor(repoWith(entries: settledOnlyEntries())));
    await tester.tap(find.text('已結帳的買菜'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'enter-edit'); // 點列表＝唯讀明細，進編輯要按鉛筆（2026-09-04）
    await tapKey(tester, 'advanced-tile');

    expect(tester.widget<ChoiceChip>(find.byKey(const Key('payer-common'))).onSelected, isNull);
    expect(tester.widget<ChoiceChip>(find.byKey(const Key('payer-$kMeId'))).onSelected, isNull);
    for (final k in const ['split-equal', 'split-ratio', 'split-amount', 'split-common']) {
      expect(tester.widget<ChoiceChip>(find.byKey(Key(k))).onSelected, isNull, reason: k);
    }
    for (final k in const ['scope-shared', 'scope-private']) {
      expect(tester.widget<ChoiceChip>(find.byKey(Key(k))).onSelected, isNull, reason: k);
    }

    await fillKey(tester, 'note-field', '只改備註');
    await tapKey(tester, 'save-button');

    final e = c.read(entriesProvider).single;
    expect(e.note, '只改備註');
    expect(e.amount, 1000);
    expect(e.scope, EntryScope.shared);
    expect(e.payerId, kMeId);
    expect(e.splitMethod, SplitMethod.equal);
    expect(e.splits.map((s) => s.share).toList(), [500.0, 500.0]);
    expect(e.settledState, SettledState.settled);
  });

  testWidgets('已結帳＋金額分攤：改備註可存，splits 不被重算覆寫也不被合計檢查擋住', (tester) async {
    final c = await pumpApp(
      tester,
      containerFor(repoWith(entries: settledAmountSplitEntries())),
    );
    await tester.tap(find.text('已結帳的金額分攤'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'enter-edit'); // 點列表＝唯讀明細，進編輯要按鉛筆（2026-09-04）

    await fillKey(tester, 'note-field', '只改備註');
    await tapKey(tester, 'save-button');

    final e = c.read(entriesProvider).single;
    expect(e.note, '只改備註');
    expect(e.amount, 567);
    expect(e.splitMethod, SplitMethod.amount);
    expect(e.splits.map((s) => s.share).toList(), [283.5, 283.5]);
  });

  testWidgets('已結帳：細項仍可改（ADR-0002），存檔後細項真的換掉', (tester) async {
    // spec ledger.md：已結帳的帳目「分類、備註、細項可改」。細項不能走 upsert_entry
    // （那支的子表寫法是全刪重建，settled 下被 policy 擋成半套），要直寫 line_items 表。
    final repo = repoWith(entries: settledWithLineItems());
    final c = await pumpApp(tester, containerFor(repo));
    await tester.tap(find.text('已結帳帶細項'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'enter-edit'); // 點列表＝唯讀明細，進編輯要按鉛筆（2026-09-04）
    await _prepareFor(tester, 'li-name-0');

    // enabled 沒明寫時是 null（＝可編輯）；唯讀會被顯式設成 false。
    expect(tester.widget<TextField>(find.byKey(const Key('li-name-0'))).enabled, isNot(false),
        reason: '已結帳也要能改細項');
    expect(tester.widget<IconButton>(find.byKey(const Key('lineitem-add'))).onPressed, isNotNull);

    await fillKey(tester, 'li-name-0', '改過的細項');
    await fillKey(tester, 'li-amount-0', '900');
    await fillKey(tester, 'note-field', '順便改備註');
    await tapKey(tester, 'save-button');

    final e = c.read(entriesProvider).single;
    expect(e.note, '順便改備註');
    expect(e.lineItems.single.name, '改過的細項');
    expect(e.lineItems.single.amount, 900);
    expect(e.amount, 1000, reason: '主筆金額仍鎖住');
    expect(e.settledState, SettledState.settled);

    // repository 也真的寫進去了（不是只有 state 對）。
    final stored = (await repo.fetchEntries(kLedgerId)).single;
    expect(stored.lineItems.single.name, '改過的細項');
  });

  testWidgets('結算中：金額鎖定但分類、備註、細項可改', (tester) async {
    final c = await pumpApp(tester, containerFor(repoWith(entries: settlingEntries())));
    await tester.tap(find.text('結算中的買菜'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'enter-edit'); // 點列表＝唯讀明細，進編輯要按鉛筆（2026-09-04）
    await _prepareFor(tester, 'amount-field');

    expect(tester.widget<TextField>(find.byKey(const Key('amount-field'))).enabled, isFalse);
    expect(find.textContaining('結算中，簽核完成或作廢後才能改金額'), findsOneWidget);
    expect(find.byKey(const Key('entry-menu')), findsNothing);

    await selectCategory(tester, 'c-dining');
    await fillKey(tester, 'note-field', '結算中也能改備註');
    await tapKey(tester, 'lineitem-add');
    await fillKey(tester, 'li-name-0', '豆腐');
    await tapKey(tester, 'save-button');

    final e = c.read(entriesProvider).single;
    expect(e.note, '結算中也能改備註');
    expect(e.categoryId, 'c-dining');
    expect(e.lineItems.single.name, '豆腐');
    expect(e.amount, 800);
    expect(e.payerId, kMeId);
    expect(e.splitMethod, SplitMethod.equal);
    expect(e.settledState, SettledState.settling);
  });

  testWidgets('點列表＝唯讀明細：欄位不可點、細項向下展開；鉛筆才進編輯', (tester) async {
    await pumpApp(tester, containerFor(repoWith(entries: settledWithLineItems())));
    await tester.tap(find.text('已結帳帶細項'));
    await tester.pumpAndSettle();

    // 唯讀：標題「明細」、沒有儲存鈕；點金額列不會開彈窗。
    expect(find.text('明細'), findsOneWidget);
    expect(find.byKey(const Key('save-button')), findsNothing);
    await tester.tap(find.byKey(const Key('edit-row-amount')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('field-done')), findsNothing, reason: '唯讀不開編輯彈窗');

    // 細項：點列向下展開，看得到細項名稱。
    await tester.tap(find.byKey(const Key('edit-row-lines')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('detail-lineitems')), findsOneWidget);
    expect(find.text('打錯的細項'), findsOneWidget);

    // 鉛筆進編輯：儲存鈕出現、點欄位開彈窗。
    await tapKey(tester, 'enter-edit');
    expect(find.byKey(const Key('save-button')), findsOneWidget);
  });

  testWidgets('沖銷：settled 筆一鍵反向＋帶原資訊重記；第二次停用', (tester) async {
    final c = await pumpApp(tester, containerFor(repoWith(entries: settledOnlyEntries())));
    await tester.tap(find.text('已結帳的買菜'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('reverse-entry')));
    await tester.tap(find.byKey(const Key('reverse-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-reverse')));
    await tester.pumpAndSettle();

    // 反向紀錄：金額/份額全負、付款照抄、標記沖銷。
    final rev = c.read(entriesProvider).firstWhere((e) => e.isAdjustment);
    expect(rev.amount, -1000);
    expect(rev.payerId, kMeId);
    expect(rev.splits.map((s) => s.share).toSet(), {-500.0});

    // 落在新增精靈且預填原資訊（金額 1000、備註同原筆）。
    expect(find.byKey(const ValueKey('form-step-0')), findsOneWidget, reason: '沖銷後帶去重新記一筆');
    expect(tester.widget<TextField>(find.byKey(const Key('amount-field'))).controller!.text, '1000');

    // 回到列表能看到反向紀錄的沖銷標籤；再進原筆，沖銷鈕已停用。
    Navigator.of(tester.element(find.byKey(const ValueKey('form-step-0')))).pop();
    await tester.pumpAndSettle();
    expect(find.text('沖銷'), findsWidgets);
    await tester.tap(find.text('已結帳的買菜').first);
    await tester.pumpAndSettle();
    final btn = tester.widget<OutlinedButton>(find.byKey(const Key('reverse-entry')));
    expect(btn.onPressed, isNull, reason: '已沖銷過不能再沖');
    expect(find.text('已沖銷'), findsOneWidget);
  });

  testWidgets('編輯：改備註後 entriesProvider 內容更新', (tester) async {
    final c = await pumpApp(tester, containerFor(repoWith(entries: oneOpenEntry())));
    await tester.tap(find.text('可刪的買菜'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'enter-edit'); // 點列表＝唯讀明細，進編輯要按鉛筆（2026-09-04）

    await fillKey(tester, 'note-field', '改過的備註');
    await tapKey(tester, 'save-button');

    final entries = c.read(entriesProvider);
    expect(entries.length, 1);
    expect(entries.single.id, 'e-open');
    expect(entries.single.note, '改過的備註');
  });

  testWidgets('刪除：確認後 entriesProvider 少一筆', (tester) async {
    final c = await pumpApp(tester, containerFor(repoWith(entries: oneOpenEntry())));
    await tester.tap(find.text('可刪的買菜'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'enter-edit'); // 點列表＝唯讀明細，進編輯要按鉛筆（2026-09-04）

    await tapKey(tester, 'entry-menu');
    await tapKey(tester, 'delete-entry');
    await tapKey(tester, 'confirm-delete');

    expect(c.read(entriesProvider), isEmpty);
  });

  testWidgets('儲存失敗：顯示錯誤，state 不留半筆（寫入成功才改 state）', (tester) async {
    final c = await pumpApp(tester, containerFor(FailingRepository(failUpsertEntry: true)));
    final before = c.read(entriesProvider).length;
    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '120');
    await selectCategory(tester, 'c-food');
    await goToStep(tester, 3);
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('boom'), findsOneWidget);
    expect(c.read(entriesProvider).length, before,
        reason: '寫入失敗時 state 不能留下那筆——樂觀更新沒回滾就是這裡會紅');
    // 失敗後儲存鈕要恢復可按，不能卡在「儲存中…」。
    expect(tester.widget<FilledButton>(find.byKey(const Key('save-button'))).onPressed, isNotNull);
  });

  testWidgets('編輯儲存失敗：顯示錯誤且原內容不動', (tester) async {
    final c = await pumpApp(tester, containerFor(FailingRepository(seed: snapshotWith(entries: oneOpenEntry()), failUpsertEntry: true)));
    await tester.tap(find.text('可刪的買菜'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'enter-edit'); // 點列表＝唯讀明細，進編輯要按鉛筆（2026-09-04）
    await fillKey(tester, 'note-field', '改不動');
    await goToStep(tester, 3);
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('boom'), findsOneWidget);
    expect(c.read(entriesProvider).single.note, '可刪的買菜');
  });

  testWidgets('刪除失敗：顯示錯誤且帳目還在', (tester) async {
    final c = await pumpApp(tester, containerFor(FailingRepository(seed: snapshotWith(entries: oneOpenEntry()), failRemoveEntry: true)));
    await tester.tap(find.text('可刪的買菜'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'enter-edit'); // 點列表＝唯讀明細，進編輯要按鉛筆（2026-09-04）
    await tapKey(tester, 'entry-menu');
    await tapKey(tester, 'delete-entry');
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('boom'), findsOneWidget);
    expect(c.read(entriesProvider).length, 1);
  });

  testWidgets('金額欄只收數字：1-2／--5／-5 全擋（修正筆已改為沖銷，無負數輸入）', (tester) async {
    await pumpApp(tester);
    await openNewForm(tester);

    String amountText() => tester.widget<TextField>(find.byKey(const Key('amount-field'))).controller!.text;

    // digitsOnly 濾掉非數字字元（不是整段拒絕）：貼上帶符號的字串會留下純數字。
    await fillKey(tester, 'amount-field', '1-2');
    expect(amountText(), '12');
    await fillKey(tester, 'amount-field', '--5');
    expect(amountText(), '5');
    await fillKey(tester, 'amount-field', '-5');
    expect(amountText(), '5');

    await fillKey(tester, 'amount-field', '120');
    expect(amountText(), '120');
  });

  testWidgets('金額只有負號 → 視同 0，下一步鎖住存不了', (tester) async {
    final c = await pumpApp(tester);
    final before = c.read(entriesProvider).length;
    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '-');

    // 負號被 digitsOnly 吃掉＝空值：第 0 關「下一步」鎖住。
    expect(tester.widget<FilledButton>(find.byKey(const Key('form-next-button'))).onPressed, isNull);
    expect(c.read(entriesProvider).length, before);
  });

  testWidgets('成員多於帳本預設比例時：每人都有比例欄，存檔比例正確', (tester) async {
    const kid = Member(id: 'm-kid', ledgerId: kLedgerId, userId: 'u3', displayName: '小孩');
    final c = await pumpApp(
      tester,
      ProviderContainer(overrides: [
        membersProvider.overrideWithValue(const [
          Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike'),
          Member(id: kWifeId, ledgerId: kLedgerId, userId: 'u2', displayName: '老婆'),
          kid,
        ]),
      ]),
    );

    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '900');
    await selectCategory(tester, 'c-food');
    await tapKey(tester, 'advanced-tile');
    await tapKey(tester, 'payer-$kMeId');
    await tapKey(tester, 'split-ratio');

    // 帳本 default_ratio 沒有小孩 → 延遲建立的 controller 帶 0，不會是 null
    expect(tester.widget<TextField>(find.byKey(const Key('ratio-m-kid'))).controller!.text, '0');

    await fillKey(tester, 'ratio-$kMeId', '40');
    await fillKey(tester, 'ratio-$kWifeId', '40');
    await fillKey(tester, 'ratio-m-kid', '20');
    await tapKey(tester, 'save-button');

    final e = c.read(entriesProvider).last;
    expect(e.splits.map((s) => s.share).toList(), [360.0, 360.0, 180.0]);
  });

  testWidgets('點擊目標 ≥44：選項 chip 與細項按鈕的命中區', (tester) async {
    await pumpApp(tester);
    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '100');
    await tapKey(tester, 'advanced-tile');
    for (final k in const ['scope-shared', 'payer-common', 'split-equal', 'split-common']) {
      expect(tester.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(44), reason: k);
    }

    await tapKey(tester, 'lineitem-add');
    expect(tester.getSize(find.byKey(const Key('lineitem-add'))).height, greaterThanOrEqualTo(44));
    // 細項刪除改左滑（2026-09-04）：拖開 action pane 後量命中區。
    await tester.drag(find.byKey(const ValueKey('li-row-0')), const Offset(-200, 0));
    await tester.pumpAndSettle();
    final size = tester.getSize(find.byKey(const Key('li-del-0')));
    expect(size.height, greaterThanOrEqualTo(44));
    expect(size.width, greaterThanOrEqualTo(44));
  });

  testWidgets('細項：空白列未填名稱時「＋」停用；儲存時空白列捨棄', (tester) async {
    final c = await pumpApp(tester);
    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '100');

    await tapKey(tester, 'lineitem-add');
    expect(tester.widget<IconButton>(find.byKey(const Key('lineitem-add'))).onPressed, isNull,
        reason: '有空白列不能再加');

    await fillKey(tester, 'li-name-0', '蛋');
    expect(tester.widget<IconButton>(find.byKey(const Key('lineitem-add'))).onPressed, isNotNull);

    await tapKey(tester, 'lineitem-add'); // 第二列留白，儲存時應被捨棄
    await fillKey(tester, 'li-amount-1', '999'); // 只有金額沒名稱，一樣捨棄
    await tapKey(tester, 'save-button');

    final e = c.read(entriesProvider).firstWhere((x) => x.amount == 100);
    expect(e.lineItems.length, 1);
    expect(e.lineItems.single.name, '蛋');
  });

  testWidgets('分類選擇器：點側邊 icon 聚焦即選中', (tester) async {
    await pumpApp(tester);
    await openNewForm(tester);
    final wheelF = find.byKey(const Key('category-wheel'));
    expect(tester.widget<CategoryWheel>(wheelF).selectedId, 'c-food');

    // 「餐飲」在側邊：點它要動畫聚焦過去並成為選中。
    await tester.tap(find.descendant(of: wheelF, matching: find.text('餐飲')));
    await tester.pumpAndSettle();
    expect(tester.widget<CategoryWheel>(wheelF).selectedId, 'c-dining');
  });

  testWidgets('分類滾輪預設選第一個分類：不動分類直接存 → categoryId=食品', (tester) async {
    final c = await pumpApp(tester);
    final before = c.read(entriesProvider).length;
    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '120');
    await tapKey(tester, 'save-button');
    expect(c.read(entriesProvider).length, before + 1);
    // 滾輪語義：永遠有選中值，預設第一個分類（食品）。
    expect(c.read(entriesProvider).any((x) => x.amount == 120 && x.categoryId == 'c-food'), isTrue);
  });

  group('資金來源（funding）', () {
    ProviderContainer foodAllocatedContainer() =>
        containerFor(repoWith(allocations: foodAndTransportAllocated()));

    testWidgets('滾輪預設分類（食品有撥款）→ 開表單即顯示資金列且預設預算', (tester) async {
      await pumpApp(tester, foodAllocatedContainer());
      await openNewForm(tester);
      await fillKey(tester, 'amount-field', '500');
      await tapKey(tester, 'advanced-tile');

      // 滾輪永遠有選中值（預設食品），資金列直接出現、預設吃 defaultFunding=預算。
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-budget'))).selected, isTrue);
    });

    testWidgets('共同錢包＋食品（本月有撥款）→ 預設預算', (tester) async {
      await pumpApp(tester, foodAllocatedContainer());
      await openNewForm(tester);
      await fillKey(tester, 'amount-field', '500');
      await selectCategory(tester, 'c-food');
      await tapKey(tester, 'advanced-tile');

      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-budget'))).selected, isTrue);
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-balance'))).selected, isFalse);
    });

    testWidgets('共同錢包＋住房（本月無撥款）→ 預設餘額', (tester) async {
      await pumpApp(tester, foodAllocatedContainer());
      await openNewForm(tester);
      await fillKey(tester, 'amount-field', '500');
      await selectCategory(tester, 'c-house');
      await tapKey(tester, 'advanced-tile');

      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-balance'))).selected, isTrue);
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-budget'))).selected, isFalse);
    });

    testWidgets('改分類到有撥款的交通，未手動選過 → 跟著變預算', (tester) async {
      await pumpApp(tester, foodAllocatedContainer());
      await openNewForm(tester);
      await fillKey(tester, 'amount-field', '500');
      await selectCategory(tester, 'c-house');
      await tapKey(tester, 'advanced-tile');
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-balance'))).selected, isTrue);

      await selectCategory(tester, 'c-transport');
      await tapKey(tester, 'advanced-tile');
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-budget'))).selected, isTrue);
    });

    testWidgets('改日期到無撥款月份 → 自動切成餘額', (tester) async {
      await pumpApp(tester, foodAllocatedContainer());
      await openNewForm(tester);
      await fillKey(tester, 'amount-field', '500');
      await selectCategory(tester, 'c-food');
      await tapKey(tester, 'advanced-tile');
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-budget'))).selected, isTrue);

      final now = DateTime.now();
      final noAllocMonth = DateTime(now.year, now.month - 1, 15); // 上月食品無撥款
      await pickDate(tester, noAllocMonth);
      await tapKey(tester, 'advanced-tile');

      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-balance'))).selected, isTrue);
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-budget'))).selected, isFalse);
    });

    testWidgets('改日期回有撥款月份 → 又切回預算', (tester) async {
      await pumpApp(tester, foodAllocatedContainer());
      await openNewForm(tester);
      await fillKey(tester, 'amount-field', '500');

      final now = DateTime.now();
      final noAllocMonth = DateTime(now.year, now.month - 1, 15);
      await pickDate(tester, noAllocMonth); // 先切到無撥款月份
      await selectCategory(tester, 'c-food');
      await tapKey(tester, 'advanced-tile');
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-balance'))).selected, isTrue);

      await pickDate(tester, now); // 改回本月（食品本月有撥款）
      await tapKey(tester, 'advanced-tile');

      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-budget'))).selected, isTrue);
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-balance'))).selected, isFalse);
    });

    testWidgets('手動選餘額後改分類到有撥款的分類 → 不覆寫，維持餘額', (tester) async {
      await pumpApp(tester, foodAllocatedContainer());
      await openNewForm(tester);
      await fillKey(tester, 'amount-field', '500');
      await selectCategory(tester, 'c-food');
      await tapKey(tester, 'advanced-tile');
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-budget'))).selected, isTrue);

      await tapKey(tester, 'funding-balance');
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-balance'))).selected, isTrue);

      await selectCategory(tester, 'c-transport'); // 交通本月也有撥款，若旗標失效會被覆寫回預算
      await tapKey(tester, 'advanced-tile');
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-balance'))).selected, isTrue,
          reason: '手動選過後，改分類不應覆寫');
    });

    testWidgets('切付款人為成員 → 資金列消失，存檔 funding=balance', (tester) async {
      final c = await pumpApp(tester, foodAllocatedContainer());
      await openNewForm(tester);
      await fillKey(tester, 'amount-field', '500');
      await selectCategory(tester, 'c-food');
      await tapKey(tester, 'advanced-tile');
      expect(find.byKey(const Key('funding-budget')), findsOneWidget);

      await tapKey(tester, 'payer-$kMeId');
      expect(find.byKey(const Key('funding-budget')), findsNothing);
      expect(find.byKey(const Key('funding-balance')), findsNothing);

      await tapKey(tester, 'split-equal');
      await tapKey(tester, 'save-button');
      expect(c.read(entriesProvider).last.funding, Funding.balance);
    });

    testWidgets('切付款人為成員後切回共同錢包 → 重算預設（食品→預算）', (tester) async {
      await pumpApp(tester, foodAllocatedContainer());
      await openNewForm(tester);
      await fillKey(tester, 'amount-field', '500');
      await selectCategory(tester, 'c-food');
      await tapKey(tester, 'advanced-tile');

      await tapKey(tester, 'payer-$kMeId');
      await tapKey(tester, 'payer-common');
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-budget'))).selected, isTrue);
    });

    testWidgets('手選餘額後切成員（列消失）再切回共同錢包 → 強制清 touched，UI 層獨立重算為預算', (tester) async {
      // 不靠存檔防禦：全程不按「儲存」，純粹驗證 UI 狀態機本身（強制 balance／清 touched／重算）成立。
      await pumpApp(tester, foodAllocatedContainer());
      await openNewForm(tester);
      await fillKey(tester, 'amount-field', '500');
      await selectCategory(tester, 'c-food');
      await tapKey(tester, 'advanced-tile');

      await tapKey(tester, 'funding-balance'); // 手動選過餘額（touched=true）
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-balance'))).selected, isTrue);

      await tapKey(tester, 'payer-$kMeId'); // 切成員 → 列消失、強制 balance、清 touched
      expect(find.byKey(const Key('funding-budget')), findsNothing);
      expect(find.byKey(const Key('funding-balance')), findsNothing);

      await tapKey(tester, 'payer-common'); // 切回共同錢包：touched 已清 → 依撥款重算
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-budget'))).selected, isTrue,
          reason: '若切成員時沒真的清掉 touched，這裡會維持使用者先前手選的餘額');
    });

    testWidgets('範圍切私人 → 不顯示資金列', (tester) async {
      await pumpApp(tester, foodAllocatedContainer());
      await openNewForm(tester);
      await fillKey(tester, 'amount-field', '500');
      await selectCategory(tester, 'c-food');
      await tapKey(tester, 'advanced-tile');
      expect(find.byKey(const Key('funding-budget')), findsOneWidget);

      await tapKey(tester, 'scope-private');
      expect(find.byKey(const Key('funding-budget')), findsNothing);
      expect(find.byKey(const Key('funding-balance')), findsNothing);
    });

    testWidgets('種類收入 → 不顯示資金列', (tester) async {
      await pumpApp(tester, foodAllocatedContainer());
      await openNewForm(tester);
      await tester.tap(find.text('收入'));
      await tester.pumpAndSettle();
      await fillKey(tester, 'amount-field', '100');
      await tapKey(tester, 'advanced-tile');

      expect(find.byKey(const Key('funding-budget')), findsNothing);
      expect(find.byKey(const Key('funding-balance')), findsNothing);
    });

    testWidgets('編輯既有帳目：載入既有 funding=budget，不被自動覆寫', (tester) async {
      final container = containerFor(repoWith(allocations: foodAndTransportAllocated(), entries: budgetFundedEntry()));
      await pumpApp(tester, container);
      await tester.tap(find.text('預算買菜'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'enter-edit');
      await tapKey(tester, 'advanced-tile');

      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-budget'))).selected, isTrue);

      // 改分類到本月無撥款的住房：既有 funding 視為已 touched，不應被自動改回餘額。
      await selectCategory(tester, 'c-house');
      await tapKey(tester, 'advanced-tile');
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-budget'))).selected, isTrue);
    });

    testWidgets('編輯既有代墊筆：切回共同錢包 → 資金列出現並依撥款重算為預算', (tester) async {
      // 代墊筆的 funding=balance 是不變式逼出來的，不是使用者選的：載入時不該當成
      // 已 touched，否則切回共同錢包時 `_syncFunding` 會被 touched 擋住、算不出預設。
      final container = containerFor(repoWith(allocations: foodAndTransportAllocated(), entries: advancedFoodEntry()));
      await pumpApp(tester, container);
      await tester.tap(find.text('代墊買菜'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'enter-edit');
      await tapKey(tester, 'advanced-tile');

      expect(find.byKey(const Key('funding-budget')), findsNothing, reason: '代墊時資金列不顯示');
      expect(find.byKey(const Key('funding-balance')), findsNothing);

      await tapKey(tester, 'payer-common');

      expect(tester.widget<ChoiceChip>(find.byKey(const Key('funding-budget'))).selected, isTrue);
    });

    testWidgets('已結帳（settled）：一定是代墊，資金列不顯示', (tester) async {
      await pumpApp(tester, containerFor(repoWith(entries: settledOnlyEntries())));
      await tester.tap(find.text('已結帳的買菜'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'advanced-tile');

      expect(find.byKey(const Key('funding-budget')), findsNothing);
      expect(find.byKey(const Key('funding-balance')), findsNothing);
    });

    testWidgets('存檔：新增食品（有撥款）不動資金選擇 → Entry.funding=budget', (tester) async {
      final c = await pumpApp(tester, foodAllocatedContainer());
      await openNewForm(tester);
      await fillKey(tester, 'amount-field', '500');
      await selectCategory(tester, 'c-food');
      await tapKey(tester, 'save-button');

      expect(c.read(entriesProvider).last.funding, Funding.budget);
    });
  });
}
