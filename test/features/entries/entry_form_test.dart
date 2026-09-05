import 'package:accounting/app/category_wheel.dart';
import 'package:accounting/app/router.dart';
import 'package:accounting/domain/balance_math.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/entries/entry_form_page.dart';
import 'package:accounting/features/entries/reversal.dart';
import 'package:accounting/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

DateTime get _thisMonth => monthOf(DateTime.now());

/// 一筆本月支出。[payerId] null ＝共同錢包付。
Entry expense({
  required String id,
  required String note,
  int amount = 300,
  String categoryId = 'c-food',
  String? payerId,
  DateTime? on,
  bool isAdjustment = false,
  List<LineItem> lineItems = const [],
}) =>
    Entry(
      id: id,
      ledgerId: kLedgerId,
      kind: EntryKind.expense,
      amount: amount,
      categoryId: categoryId,
      occurredOn: on ?? DateTime(_thisMonth.year, _thisMonth.month, 10),
      createdBy: kMeId,
      note: note,
      payerId: payerId,
      isAdjustment: isAdjustment,
      lineItems: lineItems,
    );

/// 只有一筆 Mike 先付的支出。
List<Entry> oneEntryPaidByMe() => [expense(id: 'e-mine-0001', note: '可改的買菜', payerId: kMeId)];

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

// ── 步驟精靈導航 ──────────────────────────────────────────────────────
// 各互動 key 落在哪一步；helper 先導航到該步再操作，測試本文不用自己管步驟。
// v1.5：第三關從「進階」縮成只有「誰先付」，scope-／split-／ratio-／manual- 整組消失。
const _stepOfKeyPrefix = <String, int>{
  'category-wheel': 0,
  'amount-field': 0,
  'date-button': 1,
  'note-field': 1,
  'lineitem-': 1,
  'li-name-': 1,
  'li-amount-': 1,
  'payer-': 2,
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

// 編輯 hub：編輯既有帳目＝單頁明細，各欄位點列開彈窗；步驟導航只屬於新增精靈。
const _editRowOfKeyPrefix = <String, String>{
  'category-': 'edit-row-category',
  'amount-field': 'edit-row-amount',
  'date-button': 'date-button',
  'note-field': 'edit-row-note',
  'lineitem-': 'edit-row-lines',
  'li-name-': 'edit-row-lines',
  'li-amount-': 'edit-row-lines',
  'payer-': 'edit-row-payer',
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

/// 分類橫向循環選擇器：由目前選中往目標拖整數格（單格寬＝可視寬/5）。
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

/// 切成「收入」（限定在第 0 關子樹內找，避免撞到底層帳目頁月摘要的「收入」標籤）。
Future<void> switchToIncome(WidgetTester tester) async {
  await goToStep(tester, 0);
  await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('form-step-0')), matching: find.text('收入')));
  await tester.pumpAndSettle();
}

/// 透過 `_pickDate` 打開的 [showDatePicker] 選日期：直接呼叫 [CalendarDatePicker.onDateChanged]
/// 這個公開回呼（等同使用者在日曆上點了那天），再按「OK」確認。
/// 本專案沒有配 `flutter_localizations`，Material 預設英文文案，確認鈕文字是 'OK'。
Future<void> pickDate(WidgetTester tester, DateTime date) async {
  await tapKey(tester, 'date-button');
  final picker = tester.widget<CalendarDatePicker>(find.byType(CalendarDatePicker));
  picker.onDateChanged(date);
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

bool chipSelected(WidgetTester tester, String key) =>
    tester.widget<ChoiceChip>(find.byKey(Key(key))).selected;

void main() {
  // ── 誰先付（v1.5／ADR-0009 第 8 條）──────────────────────────────────

  // 變異證明：把 initState 的 `_payerId = ref.read(currentMemberIdProvider)` 改成 null，
  // 這條會紅（chip 選中態變成「共同錢包」，存出來的 payerId 也會是 null）。
  testWidgets('新增支出預設「我先付」：chip 選中態是我，直接存 → payerId 是我', (tester) async {
    final c = await pumpApp(tester, containerFor(repoWith(entries: const [])));
    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '500');
    await selectCategory(tester, 'c-food');
    await goToStep(tester, 2);

    expect(chipSelected(tester, 'payer-$kMeId'), isTrue, reason: '預設「我」（記帳者）');
    expect(chipSelected(tester, 'payer-$kWifeId'), isFalse);
    expect(chipSelected(tester, 'payer-common'), isFalse);

    await tapKey(tester, 'save-button');
    expect(c.read(entriesProvider).single.payerId, kMeId);
  });

  testWidgets('切「共同錢包」送出 → payerId 是 null', (tester) async {
    final c = await pumpApp(tester, containerFor(repoWith(entries: const [])));
    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '500');
    await selectCategory(tester, 'c-food');
    await tapKey(tester, 'payer-common');
    expect(chipSelected(tester, 'payer-common'), isTrue);
    expect(chipSelected(tester, 'payer-$kMeId'), isFalse);

    await tapKey(tester, 'save-button');
    final e = c.read(entriesProvider).single;
    expect(e.payerId, isNull, reason: 'null ＝共同錢包付，扣共同餘額');
    expect(e.fromCommonWallet, isTrue);
  });

  testWidgets('切對方送出 → payerId 是對方', (tester) async {
    final c = await pumpApp(tester, containerFor(repoWith(entries: const [])));
    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '500');
    await selectCategory(tester, 'c-food');
    await tapKey(tester, 'payer-$kWifeId');
    expect(chipSelected(tester, 'payer-$kWifeId'), isTrue);

    await tapKey(tester, 'save-button');
    expect(c.read(entriesProvider).single.payerId, kWifeId);
  });

  // 變異證明：把 `_save` 的 `_kind == EntryKind.income ? null : _payerId` 改成直接送 `_payerId`，
  // 這條會紅——收入會帶著預設的「我」出去，撞 DB check `entries_income_no_payer`。
  testWidgets('收入：整關跳過不問誰先付，送出的 payerId 是 null', (tester) async {
    final c = await pumpApp(tester, containerFor(repoWith(entries: const [])));
    await openNewForm(tester);
    await switchToIncome(tester);
    await fillKey(tester, 'amount-field', '20000');

    // 收入只有三關：0 → 1 → 直接到確認關，中間不停在空的「誰先付」。
    expect(currentFormStep(tester), 0);
    expect(find.text('1/3'), findsOneWidget, reason: '進度要顯示三關，不是四關');
    await tester.tap(find.byKey(const Key('form-next-button')));
    await tester.pumpAndSettle();
    expect(currentFormStep(tester), 1);
    await tester.tap(find.byKey(const Key('form-next-button')));
    await tester.pumpAndSettle();
    expect(currentFormStep(tester), 3, reason: '第 2 關（誰先付）整關跳過');
    expect(find.text('3/3'), findsOneWidget);

    // 返回也要跳回第 1 關，不能倒退進那個不存在的關。
    await tester.tap(find.byKey(const Key('form-back-button')));
    await tester.pumpAndSettle();
    expect(currentFormStep(tester), 1);
    await tester.tap(find.byKey(const Key('form-next-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('payer-common')), findsNothing);
    expect(find.byKey(Key('payer-$kMeId')), findsNothing);
    expect(find.byKey(Key('payer-$kWifeId')), findsNothing);
    expect(find.byKey(const ValueKey('form-step-2')), findsNothing);

    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();
    final e = c.read(entriesProvider).single;
    expect(e.kind, EntryKind.income);
    expect(e.payerId, isNull);
  });

  testWidgets('支出維持四關：誰先付那一關走得到', (tester) async {
    await pumpApp(tester, containerFor(repoWith(entries: const [])));
    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '500');
    expect(find.text('1/4'), findsOneWidget);
    await goToStep(tester, 2);
    expect(find.byKey(const ValueKey('form-step-2')), findsOneWidget);
    expect(find.text('3/4'), findsOneWidget);
  });

  testWidgets('確認頁：支出列出「誰先付」，收入整列不出現', (tester) async {
    await pumpApp(tester, containerFor(repoWith(entries: const [])));
    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '500');
    await tapKey(tester, 'payer-$kWifeId');
    await goToStep(tester, 3);
    expect(find.byKey(const Key('edit-row-payer')), findsOneWidget);
    expect(find.text('老婆'), findsWidgets);

    await switchToIncome(tester);
    await goToStep(tester, 3);
    expect(find.byKey(const Key('edit-row-payer')), findsNothing);
    expect(find.text('誰先付'), findsNothing, reason: '收入連標題都不該出現');
  });

  testWidgets('表單裡沒有範圍與分攤方式的任何入口', (tester) async {
    await pumpApp(tester, containerFor(repoWith(entries: const [])));
    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '500');
    await goToStep(tester, 2);

    for (final k in const [
      'scope-shared',
      'scope-private',
      'split-equal',
      'split-ratio',
      'split-amount',
      'split-common',
    ]) {
      expect(find.byKey(Key(k)), findsNothing, reason: k);
    }
    final step = find.byKey(const ValueKey('form-step-2'));
    expect(step, findsOneWidget, reason: '子樹要真的存在，下面的 findsNothing 才有鑑別力');
    expect(find.descendant(of: step, matching: find.text('私人')), findsNothing);
    expect(find.descendant(of: step, matching: find.text('均分')), findsNothing);
    expect(find.descendant(of: step, matching: find.text('比例')), findsNothing);
  });

  // ── 沖銷重記 ────────────────────────────────────────────────────────

  // 變異證明：把 `buildReversal` 的 `payerId: original.payerId` 改成 `me` 或 null，
  // 這條會紅——補入剩餘就會補到錯的人頭上。
  testWidgets('沖銷：反向筆金額取負、誰先付照抄、標記 isAdjustment，並帶原資訊進新增', (tester) async {
    final c = await pumpApp(tester, containerFor(repoWith(entries: oneEntryPaidByMe())));
    await tester.tap(find.text('可改的買菜'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('enter-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-reverse')));
    await tester.pumpAndSettle();

    final rev = c.read(entriesProvider).firstWhere((e) => e.isAdjustment);
    expect(rev.amount, -300);
    expect(rev.payerId, kMeId, reason: '誰先付照抄原筆');
    expect(rev.isAdjustment, isTrue);
    expect(rev.occurredOn, oneEntryPaidByMe().single.occurredOn);

    // 接著帶原資訊進「新增」精靈重記。
    expect(find.byKey(const ValueKey('form-step-0')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('amount-field'))).controller!.text, '300');
    await goToStep(tester, 2);
    expect(chipSelected(tester, 'payer-$kMeId'), isTrue, reason: '重記預填原本的付款人');
  });

  testWidgets('沖銷共同錢包筆：反向筆 payerId 維持 null，重記預填「共同錢包」', (tester) async {
    final c = await pumpApp(tester,
        containerFor(repoWith(entries: [expense(id: 'e-wallet-01', note: '共同錢包付的水電')])));
    await tester.tap(find.text('共同錢包付的水電'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('enter-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-reverse')));
    await tester.pumpAndSettle();

    expect(c.read(entriesProvider).firstWhere((e) => e.isAdjustment).payerId, isNull);
    await goToStep(tester, 2);
    expect(chipSelected(tester, 'payer-common'), isTrue);
  });

  testWidgets('沖銷後：原筆不可再編輯，沖銷筆本身也沒有編輯入口', (tester) async {
    final orig = expense(id: 'e-orig-0001', note: '被沖銷的外送', amount: 1000, payerId: kMeId);
    final rev = expense(
      id: 'e-rev-00001',
      note: '沖銷 #${reversalTag(orig)}：被沖銷的外送',
      amount: -1000,
      payerId: kMeId,
      isAdjustment: true,
    );
    final c = await pumpApp(tester, containerFor(repoWith(entries: [orig, rev])));

    c.read(routerProvider).push('/entries/${orig.id}');
    await tester.pumpAndSettle();
    expect(find.text('明細'), findsOneWidget);
    expect(find.byKey(const Key('enter-edit')), findsNothing, reason: '已沖銷的原筆不可再編輯');
    expect(find.byKey(const Key('entry-menu')), findsNothing, reason: '已沖銷的原筆不可刪');

    Navigator.of(tester.element(find.text('明細'))).pop();
    await tester.pumpAndSettle();

    c.read(routerProvider).push('/entries/${rev.id}');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('enter-edit')), findsNothing, reason: '沖銷紀錄本身不可編輯');
    expect(find.byKey(const Key('entry-menu')), findsNothing, reason: '沖銷紀錄本身不可刪');
  });

  testWidgets('編輯一筆＝原筆＋反向筆＋新筆三筆軌跡', (tester) async {
    final c = await pumpApp(tester, containerFor(repoWith(entries: oneEntryPaidByMe())));
    await tester.tap(find.text('可改的買菜'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('enter-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-reverse')));
    await tester.pumpAndSettle();

    await fillKey(tester, 'note-field', '改過的備註');
    await tapKey(tester, 'save-button');

    final all = c.read(entriesProvider);
    expect(all.length, 3, reason: '原筆＋反向筆＋新筆');
    expect(all.where((e) => e.isAdjustment).single.amount, -300);
    expect(all.where((e) => e.note == '改過的備註').single.amount, 300);
    expect(all.any((e) => e.note == '可改的買菜'), isTrue, reason: '原筆保留');
  });

  testWidgets('沖銷確認對話框文案', (tester) async {
    await pumpApp(tester, containerFor(repoWith(entries: oneEntryPaidByMe())));
    await tester.tap(find.text('可改的買菜'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('enter-edit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('confirm-reverse')), findsOneWidget);
    expect(find.textContaining('沖銷重記'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('明細'), findsOneWidget);
  });

  // ── 鎖月 ────────────────────────────────────────────────────────────

  testWidgets('日期選到已清帳月份：日期列下錯誤行、「下一步」鎖住；換回未清月就解開', (tester) async {
    final cur = monthOf(DateTime.now());
    final prev = prevMonth(cur);
    await pumpApp(tester, containerFor(repoWith(closes: [closeFixture(month: prev)])));

    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '500');
    await pickDate(tester, DateTime(prev.year, prev.month, 15));

    expect(find.byKey(const Key('date-closed-error')), findsOneWidget);
    expect(find.text('該月已清帳'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('form-next-button'))).onPressed, isNull);

    await pickDate(tester, DateTime(cur.year, cur.month, 5));
    expect(find.byKey(const Key('date-closed-error')), findsNothing);
    expect(tester.widget<FilledButton>(find.byKey(const Key('form-next-button'))).onPressed, isNotNull);
  });

  testWidgets('編輯 hub 把日期改到已清帳月份：儲存鈕旁出現「該月已清帳」，不是靜默變灰', (tester) async {
    final cur = monthOf(DateTime.now());
    final prev = prevMonth(cur);
    // 編輯 hub＝既有帳目且非唯讀（`readOnly: false`）：路由不走這條，直接組件起來測。
    final c = containerFor(repoWith(
      entries: [expense(id: 'e-open-0001', note: '本月的筆', payerId: kMeId)],
      closes: [closeFixture(month: prev)],
    ));
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: EntryFormPage(entryId: 'e-open-0001')),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('edit-mode')), findsOneWidget);
    expect(find.byKey(const Key('date-closed-error')), findsNothing);
    expect(tester.widget<FilledButton>(find.byKey(const Key('save-button'))).onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('date-button')));
    await tester.pumpAndSettle();
    tester
        .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
        .onDateChanged(DateTime(prev.year, prev.month, 15));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('date-closed-error')), findsOneWidget);
    expect(find.text('該月已清帳'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('save-button'))).onPressed, isNull);
  });

  testWidgets('已清帳月份的帳目明細：編輯（沖銷重記）與刪除入口都不出現', (tester) async {
    final cur = monthOf(DateTime.now());
    final prev = prevMonth(cur);
    final c = await pumpApp(
      tester,
      containerFor(repoWith(
        entries: [
          expense(
              id: 'e-locked-01',
              note: '上月鎖住',
              payerId: kMeId,
              on: DateTime(prev.year, prev.month, 10)),
        ],
        closes: [closeFixture(month: prev)],
      )),
    );

    c.read(routerProvider).push('/entries/e-locked-01');
    await tester.pumpAndSettle();

    expect(find.text('明細'), findsOneWidget);
    expect(find.byKey(const Key('enter-edit')), findsNothing);
    expect(find.byKey(const Key('entry-menu')), findsNothing);
  });

  // ── 明細、刪除與失敗路徑 ────────────────────────────────────────────

  testWidgets('點列表＝唯讀明細：欄位不可點、細項向下展開', (tester) async {
    await pumpApp(
      tester,
      containerFor(repoWith(entries: [
        expense(
          id: 'e-li-00001',
          note: '帶細項的買菜',
          amount: 1000,
          payerId: kMeId,
          lineItems: const [LineItem(id: 'li-old', entryId: 'e-li-00001', name: '打錯的細項', amount: 1000)],
        ),
      ])),
    );
    await tester.tap(find.text('帶細項的買菜'));
    await tester.pumpAndSettle();

    expect(find.text('明細'), findsOneWidget);
    expect(find.byKey(const Key('save-button')), findsNothing);
    await tester.tap(find.byKey(const Key('edit-row-amount')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('field-done')), findsNothing, reason: '唯讀不開編輯彈窗');

    await tester.tap(find.byKey(const Key('edit-row-lines')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('detail-lineitems')), findsOneWidget);
    expect(find.text('打錯的細項'), findsOneWidget);
  });

  testWidgets('刪除：確認後 entriesProvider 少一筆', (tester) async {
    final c = await pumpApp(tester, containerFor(repoWith(entries: oneEntryPaidByMe())));
    await tester.tap(find.text('可改的買菜'));
    await tester.pumpAndSettle();

    await tapKey(tester, 'entry-menu');
    await tapKey(tester, 'delete-entry');
    await tapKey(tester, 'confirm-delete');

    expect(c.read(entriesProvider), isEmpty);
  });

  testWidgets('刪除失敗：顯示錯誤且帳目還在', (tester) async {
    final c = await pumpApp(
      tester,
      containerFor(FailingRepository(
          seed: snapshotWith(entries: oneEntryPaidByMe()), failRemoveEntry: true)),
    );
    await tester.tap(find.text('可改的買菜'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'entry-menu');
    await tapKey(tester, 'delete-entry');
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('boom'), findsOneWidget);
    expect(c.read(entriesProvider).length, 1);
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
    expect(tester.widget<FilledButton>(find.byKey(const Key('save-button'))).onPressed, isNotNull);
  });

  testWidgets('沖銷失敗：不留反向筆，並顯示錯誤', (tester) async {
    final c = await pumpApp(
      tester,
      containerFor(FailingRepository(
          seed: snapshotWith(entries: oneEntryPaidByMe()), failUpsertEntry: true)),
    );
    await tester.tap(find.text('可改的買菜'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('enter-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-reverse')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('boom'), findsOneWidget);
    expect(c.read(entriesProvider).where((e) => e.isAdjustment), isEmpty);
    expect(find.byKey(const ValueKey('form-step-0')), findsNothing, reason: '失敗不該帶去重記');
  });

  // ── 既有表單行為（金額、細項、分類、版面）────────────────────────────

  testWidgets('細項可加，差額只提示不擋存', (tester) async {
    final c = await pumpApp(tester, containerFor(repoWith(entries: const [])));
    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '500');
    await selectCategory(tester, 'c-food');
    await tapKey(tester, 'lineitem-add');
    await fillKey(tester, 'li-name-0', '雞蛋');
    await fillKey(tester, 'li-amount-0', '89');
    expect(find.textContaining('合計'), findsOneWidget);
    await tapKey(tester, 'save-button');

    final e = c.read(entriesProvider).single;
    expect(e.lineItems.single.name, '雞蛋');
    expect(e.lineItems.single.amount, 89);
  });

  testWidgets('細項：空白列未填名稱時「＋」停用；儲存時空白列捨棄', (tester) async {
    final c = await pumpApp(tester, containerFor(repoWith(entries: const [])));
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

    final e = c.read(entriesProvider).single;
    expect(e.lineItems.length, 1);
    expect(e.lineItems.single.name, '蛋');
  });

  testWidgets('金額欄只收數字：1-2／--5／-5 全擋（沖銷是唯一的負數來源）', (tester) async {
    await pumpApp(tester);
    await openNewForm(tester);

    String amountText() =>
        tester.widget<TextField>(find.byKey(const Key('amount-field'))).controller!.text;

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

    expect(tester.widget<FilledButton>(find.byKey(const Key('form-next-button'))).onPressed, isNull);
    expect(c.read(entriesProvider).length, before);
  });

  testWidgets('分類滾輪預設選第一個分類：不動分類直接存 → categoryId=食品', (tester) async {
    final c = await pumpApp(tester, containerFor(repoWith(entries: const [])));
    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '120');
    await tapKey(tester, 'save-button');
    expect(c.read(entriesProvider).single.categoryId, 'c-food');
  });

  testWidgets('分類選擇器：點側邊 icon 聚焦即選中', (tester) async {
    await pumpApp(tester);
    await openNewForm(tester);
    final wheelF = find.byKey(const Key('category-wheel'));
    expect(tester.widget<CategoryWheel>(wheelF).selectedId, 'c-food');

    await tester.tap(find.descendant(of: wheelF, matching: find.text('餐飲')));
    await tester.pumpAndSettle();
    expect(tester.widget<CategoryWheel>(wheelF).selectedId, 'c-dining');
  });

  testWidgets('點擊目標 ≥44：誰先付 chip 與細項按鈕的命中區', (tester) async {
    await pumpApp(tester);
    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '100');
    await goToStep(tester, 2);
    for (final k in ['payer-common', 'payer-$kMeId', 'payer-$kWifeId']) {
      expect(tester.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(44), reason: k);
    }

    await tapKey(tester, 'lineitem-add');
    expect(tester.getSize(find.byKey(const Key('lineitem-add'))).height, greaterThanOrEqualTo(44));
    await tester.drag(find.byKey(const ValueKey('li-row-0')), const Offset(-200, 0));
    await tester.pumpAndSettle();
    final size = tester.getSize(find.byKey(const Key('li-del-0')));
    expect(size.height, greaterThanOrEqualTo(44));
    expect(size.width, greaterThanOrEqualTo(44));
  });

  testWidgets('390×844：新增表單逐關都在視窗內、不爆版', (tester) async {
    await pumpApp(tester);
    await openNewForm(tester);
    expect(tester.widget<FilledButton>(find.byKey(const Key('form-next-button'))).onPressed, isNull);
    await fillKey(tester, 'amount-field', '100');

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

  testWidgets('390×667：新增表單逐關都不爆版', (tester) async {
    tester.view.physicalSize = const Size(390, 667);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const AccountingApp()));
    await tester.pumpAndSettle();

    await openNewForm(tester);
    await fillKey(tester, 'amount-field', '100');
    for (var i = 0; i <= 2; i++) {
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('form-next-button')));
      await tester.pumpAndSettle();
    }
    expect(currentFormStep(tester), 3);
    expect(tester.takeException(), isNull);
  });
}
