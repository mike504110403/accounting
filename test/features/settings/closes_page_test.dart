/// 清帳頁（v1.4／ADR-0008）：按鈕月份、預覽 sheet、二次確認、清帳列表、失敗路徑。
///
/// 資料一律走 `InMemoryLedgerRepository`——它的可清條件與訊息是逐條照 DB
/// `month_close_guard` 寫的，所以這裡測到的「什麼時候會被擋、擋了說哪句話」和線上是同一套。
///
/// 頁面自己也推算一份可清條件（決定按鈕 enabled 與那行原因），但**判定權在 RPC**：
/// 兩邊分岔時顯示 RPC 回來的訊息——底下有一條測試專門走那個分岔。
library;

import 'package:accounting/app/router.dart';
import 'package:accounting/app/theme.dart';
import 'package:accounting/domain/balance_math.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'dart:async';

import 'package:accounting/app/format.dart';
import 'package:accounting/features/settings/close_preview_sheet.dart';
import 'package:accounting/features/settings/closes_page.dart';
import 'package:accounting/features/settings/settings_page.dart';
import 'package:accounting/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

final _cur = monthOf(DateTime.now());
final _prev = prevMonth(_cur);
final _prev2 = prevMonth(_prev);

DateTime _dayIn(DateTime month, int day) => DateTime(month.year, month.month, day);

Member _member(String id, String name, {required DateTime joined, int topup = 10000}) => Member(
      id: id,
      ledgerId: kLedgerId,
      userId: 'u-$id',
      displayName: name,
      monthlyTopup: topup,
      joinedAt: joined,
    );

Entry _private(String id, String by, int amount, DateTime on) => Entry(
      id: id,
      ledgerId: kLedgerId,
      kind: EntryKind.expense,
      scope: EntryScope.private,
      amount: amount,
      categoryId: 'c-food',
      occurredOn: on,
      createdBy: by,
      payerId: by,
    );

/// 共同錢包支出（`payerId == null`）：只動共同餘額，不進任何人的個人淨變動。
Entry _sharedWallet(String id, int amount, DateTime on) => Entry(
      id: id,
      ledgerId: kLedgerId,
      kind: EntryKind.expense,
      scope: EntryScope.shared,
      amount: amount,
      categoryId: 'c-food',
      occurredOn: on,
      createdBy: kMeId,
    );

/// 有分攤列、還沒結算的拆帳：擋住清帳（`close_month: unsettled entries in month`）。
Entry _unsettledSplit(String id, DateTime on) => Entry(
      id: id,
      ledgerId: kLedgerId,
      kind: EntryKind.expense,
      scope: EntryScope.shared,
      amount: 1000,
      categoryId: 'c-food',
      occurredOn: on,
      createdBy: kMeId,
      payerId: kMeId,
      splitMethod: SplitMethod.equal,
      splits: [
        EntrySplit(entryId: id, memberId: kMeId, share: 500),
        EntrySplit(entryId: id, memberId: kWifeId, share: 500),
      ],
    );

/// 三位成員：Mike 與老婆上上個月加入（有補入額），小孩本月才加入（那個月補入額算 0）。
List<Member> _threeMembers() => [
      _member(kMeId, 'Mike', joined: _prev2),
      _member(kWifeId, '老婆', joined: _prev2),
      _member('m-kid', '小孩', joined: _cur, topup: 5000),
    ];

/// 上上個月的帳目，湊出月末餘額的三種方向：
/// Mike ＋10,000−3,000 ＝ +7,000（轉給共同）、老婆 ＋10,000−12,000 ＝ −2,000（共同補他）、
/// 小孩 0＋0 ＝ 0（免處理）；另有一筆共同錢包支出 500 讓 shared_delta ＝ −500。
List<Entry> _threeDirectionEntries() => [
      _private('e-mike', kMeId, 3000, _dayIn(_prev2, 10)),
      _private('e-wife', kWifeId, 12000, _dayIn(_prev2, 11)),
      _sharedWallet('e-wallet', 500, _dayIn(_prev2, 12)),
    ];

/// `closeMonth` 卡住不回：用來把 sheet 釘在「清帳中…」那個狀態上，
/// 驗寫入期間關不掉（下拉／點外面／系統返回都走 maybePop）。
class _HangingCloseRepository extends InMemoryLedgerRepository {
  _HangingCloseRepository({super.seed});

  final gate = Completer<void>();

  @override
  Future<MonthClose> closeMonth(String ledgerId, DateTime month) async {
    await gate.future;
    return super.closeMonth(ledgerId, month);
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

void main() {
  group('清帳按鈕：月份＝下一個可清月，可清條件不成立就 disabled ＋一行原因', () {
    testWidgets('沒清過：取最早有帳目（或成員加入）的那個月', (tester) async {
      // 成員預設上個月加入，帳目最早在上上個月 → 取兩者較早的上上個月。
      await _pump(tester, _containerFor(repoWith(entries: [_private('e-1', kMeId, 100, _dayIn(_prev2, 5))])));

      expect(find.text('清帳 ${fmtYearMonth(_prev2)}'), findsOneWidget);
      expect(find.byKey(const Key('close-disabled-reason')), findsNothing);
    });

    testWidgets('清過上上個月：下一個是上個月', (tester) async {
      await _pump(
        tester,
        _containerFor(repoWith(
          entries: [_private('e-1', kMeId, 100, _dayIn(_prev2, 5))],
          closes: [closeFixture(month: _prev2)],
        )),
      );

      expect(find.text('清帳 ${fmtYearMonth(_prev)}'), findsOneWidget);
    });

    testWidgets('上個月已清（下一個就是本月）：按鈕 disabled ＋一行「本月尚未結束」', (tester) async {
      await _pump(
        tester,
        _containerFor(repoWith(
          entries: [_private('e-1', kMeId, 100, _dayIn(_prev2, 5))],
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

    testWidgets('沒有成員也沒有帳目（推不出月份）：按鈕 disabled ＋一行「沒有可清的月份」', (tester) async {
      await _pump(
        tester,
        _containerFor(repoWith(members: const [], entries: const [], settlements: const [])),
      );

      expect(tester.widget<FilledButton>(find.byKey(const Key('close-month-button'))).onPressed, isNull);
      expect(find.text('沒有可清的月份'), findsOneWidget);
    });

    testWidgets('下一個可清月有未結算拆帳：按鈕 disabled ＋一行「有拆帳尚未簽完」', (tester) async {
      await _pump(
        tester,
        _containerFor(repoWith(
          members: _threeMembers(),
          entries: [_unsettledSplit('e-open', _dayIn(_prev2, 8))],
        )),
      );

      expect(tester.widget<FilledButton>(find.byKey(const Key('close-month-button'))).onPressed, isNull);
      expect(find.text('有拆帳尚未簽完'), findsOneWidget);
      // 月份仍寫在按鈕上：那個月確實還等著被清，只是先要把拆帳簽完。
      expect(find.text('清帳 ${fmtYearMonth(_prev2)}'), findsOneWidget);
    });

    testWidgets('沒有分攤列的拆帳不擋清帳：按鈕照常可按（擋了那個月永遠清不掉）', (tester) async {
      await _pump(
        tester,
        _containerFor(repoWith(
          members: _threeMembers(),
          entries: [
            Entry(
              id: 'e-loose',
              ledgerId: kLedgerId,
              kind: EntryKind.expense,
              scope: EntryScope.shared,
              amount: 800,
              categoryId: 'c-food',
              occurredOn: _dayIn(_prev2, 13),
              createdBy: kMeId,
              payerId: kMeId,
              splitMethod: SplitMethod.equal,
            ),
          ],
        )),
      );

      expect(tester.widget<FilledButton>(find.byKey(const Key('close-month-button'))).onPressed, isNotNull);
      expect(find.byKey(const Key('close-disabled-reason')), findsNothing);
    });
  });

  group('預覽', () {
    testWidgets('preview 被 RPC 擋下：頁內紅字（RPC 的中文訊息）、不開 sheet', (tester) async {
      // 前端推算過關（那個月沒有未結算拆帳），RPC 才是最終判定：
      // 這裡讓記憶體實作在 preview 當下才發現拆帳沒簽完，驗「分岔時以 RPC 訊息為準」。
      final repo = repoWith(members: _threeMembers(), entries: _threeDirectionEntries());
      final container = await _pump(tester, _containerFor(repo));

      // 前端看得到的資料裡沒有未簽拆帳 → 按鈕是開的。
      expect(tester.widget<FilledButton>(find.byKey(const Key('close-month-button'))).onPressed, isNotNull);
      // 按下去之前，那個月多出一筆未簽拆帳（等同「別人剛記了一筆」）。
      await repo.upsertEntry(_unsettledSplit('e-late', _dayIn(_prev2, 8)));

      await _tapCloseButton(tester);

      final error = find.byKey(const Key('close-error'));
      expect(error, findsOneWidget);
      expect(tester.widget<Text>(error).data, contains('尚未簽完'));
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
        _containerFor(repoWith(members: _threeMembers(), entries: _threeDirectionEntries())),
      );

      await _tapCloseButton(tester);

      expect(find.byType(ClosePreviewSheet), findsOneWidget);
      expect(find.text('${fmtYearMonth(_prev2)} 對帳'), findsOneWidget);
      expect(find.byKey(const Key('close-error')), findsNothing);
    });
  });

  group('預覽 sheet 的呈現（直接餵 MonthCloseDetails）', () {
    // 方向文案要湊齊 ending 正／負／零三種，預設兩位成員做不出來——
    // 這一組不經 repository，直接給 sheet 一份明細，測的是「明細怎麼被讀出來」。
    MonthCloseDetails details({List<CloseWarning> warnings = const []}) => MonthCloseDetails(
          month: _prev2,
          members: [
            closeLine(memberId: kMeId, displayName: 'Mike', topup: 10000, net: -3000),
            closeLine(memberId: kWifeId, displayName: '老婆', topup: 10000, net: -12000),
            closeLine(memberId: 'm-kid', displayName: '小孩'),
          ],
          sharedDelta: -500,
          warnings: warnings,
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

    testWidgets('三種方向文案各一例、負數月末餘額紅字、底部共同餘額變動', (tester) async {
      await pumpSheet(tester, details());

      expect(find.text('Mike 轉 7,000 給共同帳戶'), findsOneWidget); // ending > 0
      expect(find.text('共同帳戶補 老婆 2,000'), findsOneWidget); // ending < 0
      expect(find.text('免處理'), findsOneWidget); // ending == 0
      expect(find.text('共同餘額本月變動 -500'), findsOneWidget);
      // 數字欄帶正負號：正數補「+」（10,000 − 3,000 ＝ +7,000），負數沿用既有負號。
      expect(find.text('+7,000'), findsOneWidget);
      expect(find.text('-3,000'), findsOneWidget);

      final endingText = find.text('-2,000');
      expect(endingText, findsOneWidget);
      expect(
        tester.widget<Text>(endingText).style?.color,
        Theme.of(tester.element(endingText)).colorScheme.error,
      );
    });

    testWidgets('warnings 空 → 沒有警示行；非空 → 已知 code 給專屬文案、未知 code 也說得出話', (tester) async {
      await pumpSheet(tester, details());
      expect(find.byKey(const Key('close-warning-unsplit_advances')), findsNothing);

      await pumpSheet(
        tester,
        details(warnings: const [
          CloseWarning(code: 'unsplit_advances', count: 2),
          CloseWarning(code: 'something_new', count: 5),
        ]),
      );
      expect(find.text('2 筆代墊尚未拆帳，將由付款人全額承擔'), findsOneWidget);
      expect(find.text('5 筆需注意'), findsOneWidget);
    });
  });

  group('確認清帳', () {
    testWidgets('二次確認 dialog 取消：列表筆數不變、sheet 留著', (tester) async {
      final container = await _pump(
        tester,
        _containerFor(repoWith(members: _threeMembers(), entries: _threeDirectionEntries())),
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

    testWidgets('確定 → 清帳成功：sheet 關閉、SnackBar、列表多一筆', (tester) async {
      final container = await _pump(
        tester,
        _containerFor(repoWith(members: _threeMembers(), entries: _threeDirectionEntries())),
      );

      await _tapCloseButton(tester);
      await tester.tap(find.byKey(const Key('confirm-close-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('close-confirm-ok')));
      await tester.pumpAndSettle();

      expect(find.byType(ClosePreviewSheet), findsNothing);
      expect(find.text('已清帳 ${fmtYearMonth(_prev2)}'), findsOneWidget); // SnackBar
      expect(container.read(monthClosesProvider).length, 1);
      expect(container.read(monthClosesProvider).single.month, _prev2);
      // 列表那一列：月份・清帳者・日期，摘要帶各成員月末餘額。
      expect(find.textContaining('${fmtYearMonth(_prev2)}・Mike・'), findsOneWidget);
      expect(find.textContaining('Mike +7,000'), findsOneWidget);
      expect(find.text('尚未清帳'), findsNothing);
    });

    testWidgets('closeMonth 失敗：sheet 內錯誤行、解除 loading、不 pop、列表不變', (tester) async {
      final container = await _pump(
        tester,
        _containerFor(FailingRepository(
          seed: snapshotWith(members: _threeMembers(), entries: _threeDirectionEntries()),
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
        seed: snapshotWith(members: _threeMembers(), entries: _threeDirectionEntries()),
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
        members: [closeLine(memberId: kMeId, displayName: 'Mike', topup: 10000, net: -3000)],
      );
      final newer = closeFixture(
        month: _prev,
        members: [closeLine(memberId: kWifeId, displayName: '老婆', topup: 10000, net: -12000)],
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
      expect(find.text('共同帳戶補 老婆 2,000'), findsOneWidget);
      expect(find.text('共同餘額本月變動 0'), findsOneWidget);
    });
  });

  testWidgets('真實組裝（seam）：AccountingApp → 設定 → 清帳 → 預覽 → 確認 → 列表一筆，統計頁個人餘額卡回到補入額', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 一筆帳目都沒有（假資料的當月帳會讓餘額 ≠ 補入額）、兩位成員上上個月加入：
    // 清掉上上個月之後，個人餘額只剩「上個月＋本月」各補一次 10,000。
    final container = _containerFor(repoWith(
      members: [_member(kMeId, 'Mike', joined: _prev2), _member(kWifeId, '老婆', joined: _prev2)],
      entries: const [],
      allocations: const [],
      settlements: const [],
    ));
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const AccountingApp()));
    await tester.pumpAndSettle();

    container.read(routerProvider).go('/entries');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('設定'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);

    await tester.tap(find.text('清帳'));
    await tester.pumpAndSettle();
    expect(find.byType(ClosesPage), findsOneWidget);

    await _tapCloseButton(tester);
    await tester.tap(find.byKey(const Key('confirm-close-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('close-confirm-ok')));
    await tester.pumpAndSettle();

    expect(container.read(monthClosesProvider).length, 1);
    expect(find.byType(ExpansionTile), findsOneWidget);

    // 統計頁個人視角的餘額卡（月摘要 RPC 的口徑）：上上個月整段移出公式，只剩兩次補入額。
    container.read(routerProvider).go('/stats');
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byKey(const Key('view-mode-toggle')), matching: find.text('個人')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byKey(const Key('month-summary')), matching: find.text('20,000')),
      findsOneWidget,
    );
  });
}
