/// 清帳頁（v1.5／ADR-0009）：按鈕月份、預覽 sheet、二次確認、清帳列表、失敗路徑。
///
/// 資料一律走 `InMemoryLedgerRepository`——它的可清條件與訊息是逐條照 DB
/// `month_close_guard` 寫的，所以這裡測到的「什麼時候會被擋、擋了說哪句話」和線上是同一套。
///
/// 頁面自己也推算一份可清條件（決定按鈕 enabled 與那行原因），但**判定權在 RPC**：
/// 兩邊分岔時顯示 RPC 回來的訊息——底下有一條測試專門走那個分岔。
library;

import 'dart:async';

import 'package:accounting/app/format.dart';
import 'package:accounting/app/theme.dart';
import 'package:accounting/domain/balance_math.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/settings/close_preview_sheet.dart';
import 'package:accounting/features/settings/closes_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

final _cur = monthOf(DateTime.now());
final _prev = prevMonth(_cur);
final _prev2 = prevMonth(_prev);

DateTime _dayIn(DateTime month, int day) => DateTime(month.year, month.month, day);

Member _member(String id, String name, {required DateTime joined}) => Member(
      id: id,
      ledgerId: kLedgerId,
      userId: 'u-$id',
      displayName: name,
      joinedAt: joined,
    );

/// [by] 先付的支出。
Entry _paidBy(String id, String by, int amount, DateTime on) => Entry(
      id: id,
      ledgerId: kLedgerId,
      kind: EntryKind.expense,
      amount: amount,
      categoryId: 'c-food',
      occurredOn: on,
      createdBy: by,
      payerId: by,
    );

/// 共同錢包支出（`payerId == null`）：只動共同餘額，不進任何人的月末。
Entry _sharedWallet(String id, int amount, DateTime on) => Entry(
      id: id,
      ledgerId: kLedgerId,
      kind: EntryKind.expense,
      amount: amount,
      categoryId: 'c-food',
      occurredOn: on,
      createdBy: kMeId,
    );

/// 三位成員：Mike 與老婆上上個月加入（最早可清月＝上上個月），小孩本月才加入
/// （那個月補入與先付都算 0）。
List<Member> _threeMembers() => [
      _member(kMeId, 'Mike', joined: _prev2),
      _member(kWifeId, '老婆', joined: _prev2),
      _member('m-kid', '小孩', joined: _cur),
    ];

/// 上上個月的補入與帳目，湊出月末的三種方向：
/// Mike 補入 10,000 − 先付 3,000 ＝ ending +7,000（轉給共同）、
/// 老婆補入 10,000 − 先付 12,000 ＝ ending −2,000（共同補他）、
/// 另有一筆共同錢包支出 500（對照列）。應記共同收入＝7,000−2,000＝5,000。
List<Entry> _threeDirectionEntries() => [
      _paidBy('e-mike', kMeId, 3000, _dayIn(_prev2, 10)),
      _paidBy('e-wife', kWifeId, 12000, _dayIn(_prev2, 11)),
      _sharedWallet('e-wallet', 500, _dayIn(_prev2, 12)),
    ];

List<PersonalTopup> _threeDirectionTopups() => [
      topupFixture(memberId: kMeId, amount: 10000, occurredOn: _dayIn(_prev2, 1)),
      topupFixture(memberId: kWifeId, amount: 10000, occurredOn: _dayIn(_prev2, 1)),
    ];

/// 兩位成員月末剛好互相抵銷（+2,000 ／ −2,000）：應記共同收入邊界值 0。
List<Entry> _zeroSumEntries() => [
      _paidBy('e-mike0', kMeId, 3000, _dayIn(_prev2, 10)), // topup 5000 → ending +2000
      _paidBy('e-wife0', kWifeId, 7000, _dayIn(_prev2, 11)), // topup 5000 → ending -2000
    ];

List<PersonalTopup> _zeroSumTopups() => [
      topupFixture(memberId: kMeId, amount: 5000, occurredOn: _dayIn(_prev2, 1)),
      topupFixture(memberId: kWifeId, amount: 5000, occurredOn: _dayIn(_prev2, 1)),
    ];

/// `closeMonth` 卡住不回：用來把 sheet 釘在「清帳中…」那個狀態上，
/// 驗寫入期間關不掉（下拉／點外面／系統返回都走 maybePop）。
class _HangingCloseRepository extends InMemoryLedgerRepository {
  _HangingCloseRepository({super.seed});

  final gate = Completer<void>();

  @override
  Future<MonthClose> closeMonth(String ledgerId, DateTime month, {bool recordIncome = true}) async {
    await gate.future;
    return super.closeMonth(ledgerId, month, recordIncome: recordIncome);
  }
}

/// 記下 `closeMonth` 實際收到的 `recordIncome`——用來驗「勾選框停用時到底送了什麼」，
/// 不能只看效果（`incomeAmount == 0` 時不管 `recordIncome` 是不是 true 都不會記那筆收入，
/// 光看「沒有多一筆」測不出真正傳的值）。
class _RecordIncomeSpyRepository extends InMemoryLedgerRepository {
  _RecordIncomeSpyRepository({super.seed});

  bool? lastRecordIncome;

  @override
  Future<MonthClose> closeMonth(String ledgerId, DateTime month, {bool recordIncome = true}) {
    lastRecordIncome = recordIncome;
    return super.closeMonth(ledgerId, month, recordIncome: recordIncome);
  }
}

ProviderContainer _containerFor(LedgerRepository repo) =>
    ProviderContainer(overrides: [ledgerRepositoryProvider.overrideWithValue(repo)]);

/// 只掛清帳頁的測試殼（頁面本身不依賴 /settings 的存在）。
Future<ProviderContainer> _pump(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const ClosesPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _tapCloseButton(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('close-month-button')));
  await tester.pumpAndSettle();
}

/// 給 390×667 不爆版測試用的範例明細（與「預覽 sheet 的呈現」那組的 `details()` 同構）。
MonthCloseDetails _sampleCloseDetails() => MonthCloseDetails(
      month: _prev2,
      members: [
        closeLine(memberId: kMeId, displayName: 'Mike', topup: 10000, paid: 3000),
        closeLine(memberId: kWifeId, displayName: '老婆', topup: 10000, paid: 12000),
      ],
      sharedPaid: 500,
      incomeAmount: 5000,
    );

void main() {
  group('清帳按鈕：月份＝下一個可清月，可清條件不成立就 disabled ＋一行原因', () {
    testWidgets('沒清過：取最早有帳目（或成員加入、補入）的那個月', (tester) async {
      // 成員預設上個月加入，帳目最早在上上個月 → 取三者較早的上上個月。
      await _pump(tester, _containerFor(repoWith(entries: [_paidBy('e-1', kMeId, 100, _dayIn(_prev2, 5))])));

      expect(find.text('清帳 ${fmtYearMonth(_prev2)}'), findsOneWidget);
      expect(find.byKey(const Key('close-disabled-reason')), findsNothing);
    });

    testWidgets('清過上上個月：下一個是上個月', (tester) async {
      await _pump(
        tester,
        _containerFor(repoWith(
          entries: [_paidBy('e-1', kMeId, 100, _dayIn(_prev2, 5))],
          closes: [closeFixture(month: _prev2)],
        )),
      );

      expect(find.text('清帳 ${fmtYearMonth(_prev)}'), findsOneWidget);
    });

    testWidgets('上個月已清（下一個就是本月）：按鈕 disabled ＋一行「本月尚未結束」', (tester) async {
      await _pump(
        tester,
        _containerFor(repoWith(
          entries: [_paidBy('e-1', kMeId, 100, _dayIn(_prev2, 5))],
          closes: [closeFixture(month: _prev2), closeFixture(month: _prev)],
        )),
      );

      expect(tester.widget<FilledButton>(find.byKey(const Key('close-month-button'))).onPressed, isNull);
      expect(find.byKey(const Key('close-disabled-reason')), findsOneWidget);
      expect(find.text('本月尚未結束'), findsOneWidget);
      // 那個月清不了，按鈕上就不寫月份（不邀請使用者去清一個清不了的月）。
      expect(
        find.descendant(
            of: find.byKey(const Key('close-month-button')), matching: find.text('清帳')),
        findsOneWidget,
      );
    });

    testWidgets('沒有成員、帳目、補入（推不出月份）：按鈕 disabled ＋一行「沒有可清的月份」', (tester) async {
      await _pump(
        tester,
        _containerFor(repoWith(members: const [], entries: const [], topups: const [])),
      );

      expect(tester.widget<FilledButton>(find.byKey(const Key('close-month-button'))).onPressed, isNull);
      expect(find.text('沒有可清的月份'), findsOneWidget);
    });
  });

  group('nextClosableMonth（純函式）：三個來源（成員加入／帳目／補入）都要考慮', () {
    test('沒有帳目、只有補入：以補入月份為最早可清月', () {
      // 成員本身加入月較晚，唯一比它早的線索是補入——刪掉補入那段迴圈這條就會紅。
      final result = nextClosableMonth(
        closes: const [],
        members: [_member(kMeId, 'Mike', joined: DateTime(2025, 5, 1))],
        entries: const [],
        topups: [topupFixture(memberId: kMeId, amount: 1000, occurredOn: DateTime(2025, 1, 10))],
      );

      expect(result, DateTime(2025, 1, 1));
    });

    test('成員加入月早於帳目與補入：以成員加入月為最早可清月', () {
      final result = nextClosableMonth(
        closes: const [],
        members: [_member(kMeId, 'Mike', joined: DateTime(2025, 1, 1))],
        entries: [_paidBy('e-1', kMeId, 100, DateTime(2025, 6, 15))],
        topups: [topupFixture(memberId: kMeId, amount: 1000, occurredOn: DateTime(2025, 9, 1))],
      );

      expect(result, DateTime(2025, 1, 1));
    });
  });

  group('預覽', () {
    testWidgets('preview 被 RPC 擋下（分岔）：頁內紅字（RPC 的中文訊息）、不開 sheet', (tester) async {
      // 前端推算出來的月份沒問題（按鈕是開的），但按下去之前那個月被別的裝置搶先清掉了：
      // RPC 才是最終判定，這裡驗「分岔時以 RPC 訊息為準」。
      final repo = repoWith(entries: _threeDirectionEntries(), topups: _threeDirectionTopups());
      final container = await _pump(tester, _containerFor(repo));

      expect(tester.widget<FilledButton>(find.byKey(const Key('close-month-button'))).onPressed, isNotNull);
      // 繞過前端 provider 直接清掉（模擬別的裝置）：頁面的 monthClosesProvider 還沒重讀，仍以為沒清。
      await repo.closeMonth(kLedgerId, _prev2);

      await _tapCloseButton(tester);

      final error = find.byKey(const Key('close-error'));
      expect(error, findsOneWidget);
      expect(tester.widget<Text>(error).data, '該月已清帳');
      expect(
        tester.widget<Text>(error).style?.color,
        Theme.of(tester.element(error)).colorScheme.error,
      );
      expect(find.byType(ClosePreviewSheet), findsNothing);
      expect(container.read(monthClosesProvider), isEmpty);
    });

    testWidgets('preview 成功就開 sheet（標題＝該月對帳）', (tester) async {
      await _pump(
        tester,
        _containerFor(repoWith(entries: _threeDirectionEntries(), topups: _threeDirectionTopups())),
      );

      await _tapCloseButton(tester);

      expect(find.byType(ClosePreviewSheet), findsOneWidget);
      expect(find.text('${fmtYearMonth(_prev2)} 對帳'), findsOneWidget);
      expect(find.byKey(const Key('close-error')), findsNothing);
    });
  });

  group('預覽 sheet 的呈現（直接餵 MonthCloseDetails）', () {
    // 方向文案要湊齊 ending 正／負／零三種：兩位成員做不出「免處理」那格，
    // 這一組不經 repository，直接給 sheet 一份明細，測的是「明細怎麼被讀出來」。
    MonthCloseDetails details({int sharedPaid = 500, int? incomeAmount = 5000}) => MonthCloseDetails(
          month: _prev2,
          members: [
            closeLine(memberId: kMeId, displayName: 'Mike', topup: 10000, paid: 3000), // ending +7000
            closeLine(memberId: kWifeId, displayName: '老婆', topup: 10000, paid: 12000), // ending -2000
            closeLine(memberId: 'm-kid', displayName: '小孩'), // topup/paid 都 0 → ending 0
          ],
          sharedPaid: sharedPaid,
          incomeAmount: incomeAmount,
        );

    Future<void> pumpSheet(WidgetTester tester, MonthCloseDetails d) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: ClosePreviewSheet(month: _prev2, details: d)),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('三種方向文案各一例、負數月末紅字、共同錢包支出對照列', (tester) async {
      await pumpSheet(tester, details());

      expect(find.text('Mike 轉 7,000 給共同帳戶'), findsOneWidget); // ending > 0
      expect(find.text('共同帳戶補 老婆 2,000'), findsOneWidget); // ending < 0
      expect(find.text('免處理'), findsOneWidget); // ending == 0
      expect(find.text('共同錢包支出 500'), findsOneWidget);
      expect(find.text('+7,000'), findsOneWidget);

      final endingText = find.text('-2,000');
      expect(endingText, findsOneWidget);
      expect(
        tester.widget<Text>(endingText).style?.color,
        Theme.of(tester.element(endingText)).colorScheme.error,
      );
    });

    testWidgets('incomeAmount > 0：勾選框預設勾且顯示金額，整列可點', (tester) async {
      await pumpSheet(tester, details(incomeAmount: 5000));

      final checkbox =
          tester.widget<CheckboxListTile>(find.byKey(const Key('record-income-checkbox')));
      expect(checkbox.value, isTrue);
      expect(checkbox.onChanged, isNotNull);
      expect(find.text('一鍵記共同收入 5,000'), findsOneWidget);

      // 整列可點（不是只有小方塊）：點文字所在的 tile 也能 toggle。
      await tester.tap(find.byKey(const Key('record-income-checkbox')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<CheckboxListTile>(find.byKey(const Key('record-income-checkbox'))).value,
        isFalse,
      );
    });

    testWidgets('incomeAmount <= 0：勾選框停用、強制不勾，顯示「本月無需轉入」', (tester) async {
      await pumpSheet(tester, details(incomeAmount: -1000));

      final checkbox =
          tester.widget<CheckboxListTile>(find.byKey(const Key('record-income-checkbox')));
      expect(checkbox.onChanged, isNull);
      expect(checkbox.value, isFalse);
      expect(find.text('本月無需轉入'), findsOneWidget);
      expect(find.textContaining('一鍵記共同收入'), findsNothing);
    });

    testWidgets('incomeAmount 為 null（RPC 沒給）：勾選框照常可勾且預設勾，金額顯示「—」', (tester) async {
      await pumpSheet(tester, details(incomeAmount: null));

      final checkbox =
          tester.widget<CheckboxListTile>(find.byKey(const Key('record-income-checkbox')));
      expect(checkbox.value, isTrue);
      expect(checkbox.onChanged, isNotNull);
      expect(find.text('一鍵記共同收入 —'), findsOneWidget);
    });
  });

  group('確認清帳', () {
    testWidgets('二次確認 dialog 取消：列表筆數不變、sheet 留著', (tester) async {
      final container = await _pump(
        tester,
        _containerFor(repoWith(entries: _threeDirectionEntries(), topups: _threeDirectionTopups())),
      );
      final before = container.read(monthClosesProvider).length;

      await _tapCloseButton(tester);
      await tester.tap(find.byKey(const Key('confirm-close-button')));
      await tester.pumpAndSettle();
      expect(find.text('清帳後不可撤銷，該月及更早月份的帳目將鎖定。'), findsOneWidget);

      await tester.tap(find.byKey(const Key('close-confirm-cancel')));
      await tester.pumpAndSettle();

      expect(container.read(monthClosesProvider).length, before);
      expect(find.byType(ClosePreviewSheet), findsOneWidget);
    });

    testWidgets('確定（勾選維持預設）→ 清帳成功：sheet 關閉、SnackBar、列表多一筆、多記一筆「清帳轉入」收入', (tester) async {
      final repo = repoWith(entries: _threeDirectionEntries(), topups: _threeDirectionTopups());
      final container = await _pump(tester, _containerFor(repo));
      final entriesBefore = container.read(entriesProvider).length;

      await _tapCloseButton(tester);
      await tester.tap(find.byKey(const Key('confirm-close-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('close-confirm-ok')));
      await tester.pumpAndSettle();

      expect(find.byType(ClosePreviewSheet), findsNothing);
      expect(find.text('已清帳 ${fmtYearMonth(_prev2)}'), findsOneWidget); // SnackBar
      expect(container.read(monthClosesProvider).length, 1);
      final close = container.read(monthClosesProvider).single;
      expect(close.month, _prev2);
      expect(close.incomeEntryId, isNotNull);
      // 列表那一列：月份・清帳者・日期，摘要帶各成員月末。
      expect(find.textContaining('${fmtYearMonth(_prev2)}・Mike・'), findsOneWidget);
      expect(find.textContaining('Mike +7,000'), findsOneWidget);
      expect(find.text('尚未清帳'), findsNothing);

      // 「一鍵記共同收入」：多一筆落在「清帳轉入」分類的收入，金額＝7,000−2,000＝5,000。
      expect(container.read(entriesProvider).length, entriesBefore + 1);
      final categories = await repo.fetchCategories(kLedgerId);
      final incomeCategory = categories.singleWhere((c) => c.name == '清帳轉入');
      final incomeEntry =
          container.read(entriesProvider).singleWhere((e) => e.id == close.incomeEntryId);
      expect(incomeEntry.kind, EntryKind.income);
      expect(incomeEntry.amount, 5000);
      expect(incomeEntry.categoryId, incomeCategory.id);
    });

    testWidgets('取消勾選「一鍵記共同收入」→ closeMonth 的 recordIncome 為 false，沒有新增收入', (tester) async {
      final repo = repoWith(entries: _threeDirectionEntries(), topups: _threeDirectionTopups());
      final container = await _pump(tester, _containerFor(repo));
      final entriesBefore = container.read(entriesProvider).length;

      await _tapCloseButton(tester);
      await tester.tap(find.byKey(const Key('record-income-checkbox')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-close-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('close-confirm-ok')));
      await tester.pumpAndSettle();

      expect(container.read(monthClosesProvider).length, 1);
      expect(container.read(monthClosesProvider).single.incomeEntryId, isNull);
      expect(container.read(entriesProvider).length, entriesBefore);
    });

    testWidgets('incomeAmount＝0（邊界）：勾選框停用、實際送出的 recordIncome 為 false，不記收入', (tester) async {
      final repo = _RecordIncomeSpyRepository(
        seed: snapshotWith(entries: _zeroSumEntries(), topups: _zeroSumTopups()),
      );
      final container = await _pump(tester, _containerFor(repo));
      final entriesBefore = container.read(entriesProvider).length;

      await _tapCloseButton(tester);

      final checkbox =
          tester.widget<CheckboxListTile>(find.byKey(const Key('record-income-checkbox')));
      expect(checkbox.onChanged, isNull, reason: 'incomeAmount == 0 也算「已知不需要轉入」，要停用');
      expect(checkbox.value, isFalse);
      expect(find.text('本月無需轉入'), findsOneWidget);

      await tester.tap(find.byKey(const Key('confirm-close-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('close-confirm-ok')));
      await tester.pumpAndSettle();

      expect(repo.lastRecordIncome, isFalse);
      expect(container.read(monthClosesProvider).single.incomeEntryId, isNull);
      expect(container.read(entriesProvider).length, entriesBefore);
    });

    testWidgets('closeMonth 失敗：sheet 內錯誤行、解除 loading、不 pop、列表不變', (tester) async {
      final container = await _pump(
        tester,
        _containerFor(FailingRepository(
          seed: snapshotWith(entries: _threeDirectionEntries(), topups: _threeDirectionTopups()),
          failCloseMonth: true,
        )),
      );

      await _tapCloseButton(tester);
      await tester.tap(find.byKey(const Key('confirm-close-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('close-confirm-ok')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('close-sheet-error')), findsOneWidget);
      expect(find.byType(ClosePreviewSheet), findsOneWidget); // 沒 pop
      // loading 解除＝按鈕回到可按、文字回到「確認清帳」。
      final button = tester.widget<FilledButton>(find.byKey(const Key('confirm-close-button')));
      expect(button.onPressed, isNotNull);
      expect(find.text('確認清帳'), findsOneWidget);
      expect(container.read(monthClosesProvider), isEmpty);
    });

    testWidgets('清帳寫入中：sheet 關不掉（系統返回與點外面都不生效），寫完才收', (tester) async {
      final repo = _HangingCloseRepository(
        seed: snapshotWith(entries: _threeDirectionEntries(), topups: _threeDirectionTopups()),
      );
      final container = await _pump(tester, _containerFor(repo));

      await _tapCloseButton(tester);
      await tester.tap(find.byKey(const Key('confirm-close-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('close-confirm-ok')));
      await tester.pump(); // 進 loading，closeMonth 還卡在 gate 上

      expect(find.text('清帳中…'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('confirm-close-button'))).onPressed, isNull);

      // 系統返回：不生效（pumpAndSettle 讓關閉動畫真的有機會跑完，否則是假綠）。
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ClosePreviewSheet), findsOneWidget, reason: '寫入中被系統返回關掉了');

      // 點 sheet 外面（barrier）：也不生效。
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.byType(ClosePreviewSheet), findsOneWidget, reason: '寫入中被點外面關掉了');

      // 寫入完成才收，且列表真的多一筆。
      repo.gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(ClosePreviewSheet), findsNothing);
      expect(container.read(monthClosesProvider).length, 1);
    });
  });

  group('清帳列表', () {
    testWidgets('空清單顯示「尚未清帳」', (tester) async {
      await _pump(tester, _containerFor(repoWith(members: _threeMembers())));

      expect(find.text('尚未清帳'), findsOneWidget);
      expect(find.byType(ExpansionTile), findsNothing);
    });

    testWidgets('清帳時間帶年份且補零：12 月清掉 11 月，那列寫 2026/12/01', (tester) async {
      // 跨年是常態（2026／01 清掉 2025／12），所以清帳時間一定要看得出年份。
      await _pump(
        tester,
        _containerFor(repoWith(
          members: _threeMembers(),
          closes: [
            closeFixture(
              month: DateTime(2026, 11, 1),
              closedAt: DateTime(2026, 12, 1, 9, 30),
              members: [closeLine(memberId: kMeId, displayName: 'Mike', topup: 10000)],
            ),
          ],
        )),
      );

      expect(find.text('2026／11・Mike・2026/12/01'), findsOneWidget);
    });

    testWidgets('依月份倒序、點列才展開完整明細', (tester) async {
      final older = closeFixture(
        month: _prev2,
        members: [closeLine(memberId: kMeId, displayName: 'Mike', topup: 10000, paid: 13000)], // -3000
      );
      final newer = closeFixture(
        month: _prev,
        members: [closeLine(memberId: kWifeId, displayName: '老婆', topup: 10000, paid: 22000)], // -12000
      );
      await _pump(
        tester,
        _containerFor(repoWith(members: _threeMembers(), closes: [older, newer])),
      );

      // 倒序：上個月那列在上上個月那列前面。
      final tiles = find.byType(ExpansionTile);
      expect(tiles, findsNWidgets(2));
      expect(tester.getTopLeft(tiles.at(0)).dy, lessThan(tester.getTopLeft(tiles.at(1)).dy));
      expect(
        find.descendant(of: tiles.at(0), matching: find.textContaining(fmtYearMonth(_prev))),
        findsOneWidget,
      );

      // 收起時只有摘要，沒有方向文案。
      expect(find.text('共同帳戶補 老婆 12,000'), findsNothing);
      await tester.tap(find.textContaining('${fmtYearMonth(_prev)}・'));
      await tester.pumpAndSettle();
      expect(find.text('共同帳戶補 老婆 12,000'), findsOneWidget);
      expect(find.text('共同錢包支出 0'), findsOneWidget);
    });
  });

  group('390×667 不爆版（無 overflow）', () {
    testWidgets('清帳頁', (tester) async {
      tester.view.physicalSize = const Size(390, 667);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = _containerFor(repoWith(
        members: _threeMembers(),
        closes: [
          closeFixture(
            month: _prev2,
            members: [closeLine(memberId: kMeId, displayName: 'Mike', topup: 10000, paid: 3000)],
          ),
        ],
      ));
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: buildTheme(Brightness.light), home: const ClosesPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('預覽 sheet', (tester) async {
      tester.view.physicalSize = const Size(390, 667);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: ClosePreviewSheet(month: _prev2, details: _sampleCloseDetails())),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
