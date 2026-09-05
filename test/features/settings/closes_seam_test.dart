/// 真實組裝（seam）測試：`AccountingApp` → 設定 → 清帳 → 預覽 → 確認 → 列表一筆
/// ＋「一鍵記共同收入」真的落地（spec v1.5「清帳」節／ADR-0009）。
///
/// **不斷言帳目頁畫面**：帳目頁預設顯示本月，清帳記的那筆收入落在**上一個月最後一天**
/// （`_prev2` 月底），本來就不會出現在帳目頁預設畫面裡；帳目頁列表顯示的是 `note`
/// （「YYYY／MM 清帳」）不是分類名，`find.textContaining('清帳轉入')` 在帳目頁上本來
/// 就該找不到。「那筆收入真的記對了」改在 provider 狀態層斷金額與日期，不管帳目頁
/// 怎麼畫都測得到、也不會因為斷言方式錯誤而測出偽陽性。
///
/// 獨立成一個檔案，不跟 `closes_page_test.dart` 放一起：這個測試 import 了
/// `app/router.dart`／`main.dart`，那條鏈目前會拉進其他波 3 工人尚未對齊 v1.5 的
/// entries/stats/lists/budget 頁面（`lib/features／lib/app 目前整體編不過是預期`）
/// ——本波 `flutter test` 在這個檔案註定編不過，是已知環境阻擋；放單獨檔案才不會
/// 拖累 `closes_page_test.dart`／`settings_page_test.dart` 裡其他已經跑得動的測試。
/// 合併回 `feature/rules-v15`（其餘工人的改動落地）後由大腦重跑這個檔案。
library;

import 'package:accounting/app/router.dart';
import 'package:accounting/domain/balance_math.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/settings/closes_page.dart';
import 'package:accounting/features/settings/settings_page.dart';
import 'package:accounting/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

final _prev2 = prevMonth(prevMonth(monthOf(DateTime.now())));

DateTime _dayIn(DateTime month, int day) => DateTime(month.year, month.month, day);

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

ProviderContainer _containerFor(LedgerRepository repo) =>
    ProviderContainer(overrides: [ledgerRepositoryProvider.overrideWithValue(repo)]);

void main() {
  testWidgets(
    '真實組裝（seam）：AccountingApp → 設定 → 清帳 → 預覽 → 確認 → 列表一筆＋一鍵記共同收入落地',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // 上上個月：Mike 補入 10,000 − 先付 3,000 ＝ +7,000、老婆補入 10,000 − 先付 12,000 ＝ −2,000、
      // 共同錢包付 500（對照列）。應記共同收入＝7,000 − 2,000 ＝ 5,000（> 0，會記那筆收入）。
      final container = _containerFor(repoWith(
        entries: [
          _paidBy('e-mike', kMeId, 3000, _dayIn(_prev2, 10)),
          _paidBy('e-wife', kWifeId, 12000, _dayIn(_prev2, 11)),
          _sharedWallet('e-wallet', 500, _dayIn(_prev2, 12)),
        ],
        topups: [
          topupFixture(memberId: kMeId, amount: 10000, occurredOn: _dayIn(_prev2, 1)),
          topupFixture(memberId: kWifeId, amount: 10000, occurredOn: _dayIn(_prev2, 1)),
        ],
      ));
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const AccountingApp()),
      );
      await tester.pumpAndSettle();

      container.read(routerProvider).go('/entries');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('設定'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);

      await tester.tap(find.text('清帳'));
      await tester.pumpAndSettle();
      expect(find.byType(ClosesPage), findsOneWidget);

      await tester.tap(find.byKey(const Key('close-month-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-close-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('close-confirm-ok')));
      await tester.pumpAndSettle();

      // UI 端只斷言「清帳列表多一列」：帳目頁預設顯示本月，這筆收入落在上一個月
      // 最後一天，本來就不會出現在帳目頁預設畫面裡，不在這裡斷言帳目頁。
      expect(container.read(monthClosesProvider).length, 1);
      expect(find.byType(ExpansionTile), findsOneWidget);

      // 「一鍵記共同收入」真的落地：金額與日期在 provider 狀態層驗，不管帳目頁
      // 怎麼畫都測得到——金額＝7,000（Mike 應轉入）− 2,000（老婆應補出）＝5,000；
      // 日期＝清帳月（_prev2）最後一天。
      final close = container.read(monthClosesProvider).single;
      expect(close.incomeEntryId, isNotNull);
      final incomeEntry =
          container.read(entriesProvider).singleWhere((e) => e.id == close.incomeEntryId);
      expect(incomeEntry.kind, EntryKind.income);
      expect(incomeEntry.amount, 5000);
      expect(incomeEntry.occurredOn, DateTime(_prev2.year, _prev2.month + 1, 0));
    },
  );
}
