import 'package:accounting/domain/balance_math.dart';
import 'package:accounting/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 錢公式（spec v1.4／ADR-0008）。每條規則一段獨立 fixture：一段只讓一條規則生效，
/// 避免互相遮蔽。日期全部寫死在**過去**（2026-03～2026-05），不吃 `DateTime.now()`——
/// 只有 [personalBalance] 的補入額上界會夾在「本月」，寫死過去的月份不會被那道夾擠改變。
void main() {
  const lid = 'l';
  const meId = 'm-a';
  const wifeId = 'm-b';

  Ledger ledger(int opening) => Ledger(
        id: lid,
        name: '我們的家',
        inviteCode: 'A7K3QZ',
        defaultRatio: const {meId: 50, wifeId: 50},
        openingBalanceShared: opening,
      );

  Member member(String id, {int topup = 0}) => Member(
        id: id,
        ledgerId: lid,
        userId: 'u-$id',
        displayName: id,
        monthlyTopup: topup,
        // joinedAt 只給 personalBalance 的呼叫端取月初用，這裡一律顯式傳 joinedMonth，
        // 所以固定成 epoch，避免測試依賴這個欄位。
        joinedAt: DateTime(1970),
      );

  final may1 = DateTime(2026, 5, 1);
  final may31 = DateTime(2026, 5, 31);
  final apr1 = DateTime(2026, 4, 1);
  final mar1 = DateTime(2026, 3, 1);
  DateTime may(int d) => DateTime(2026, 5, d);
  DateTime apr(int d) => DateTime(2026, 4, d);

  /// 共同錢包支出（payer 為 null）。
  Entry wallet(String id, int amount, DateTime on, {String cat = 'c-food'}) => Entry(
        id: id,
        ledgerId: lid,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: amount,
        categoryId: cat,
        occurredOn: on,
        createdBy: meId,
      );

  /// 代墊：付款人是成員，均分兩人（分攤額是 numeric(12,2)，這裡照樣給小數）。
  Entry advanced(
    String id,
    int amount,
    DateTime on, {
    String payer = meId,
    String cat = 'c-food',
    SettledState settledState = SettledState.open,
  }) =>
      Entry(
        id: id,
        ledgerId: lid,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: amount,
        categoryId: cat,
        occurredOn: on,
        createdBy: payer,
        payerId: payer,
        splitMethod: SplitMethod.equal,
        settledState: settledState,
        splits: [
          EntrySplit(entryId: id, memberId: meId, share: amount / 2),
          EntrySplit(entryId: id, memberId: wifeId, share: amount / 2),
        ],
      );

  Entry sharedIncome(String id, int amount, DateTime on) => Entry(
        id: id,
        ledgerId: lid,
        kind: EntryKind.income,
        scope: EntryScope.shared,
        amount: amount,
        categoryId: 'c-salary',
        occurredOn: on,
        createdBy: meId,
      );

  Entry privateEntry(String id, int amount, DateTime on,
          {required EntryKind kind, required String who}) =>
      Entry(
        id: id,
        ledgerId: lid,
        kind: kind,
        scope: EntryScope.private,
        amount: amount,
        categoryId: kind == EntryKind.expense ? 'c-fun' : 'c-bonus',
        occurredOn: on,
        createdBy: who,
        payerId: who,
      );

  BudgetAllocation alloc(String id, int amount, DateTime on, {String cat = 'c-food'}) =>
      BudgetAllocation(
          id: id, ledgerId: lid, categoryId: cat, amount: amount, occurredOn: on, createdBy: meId);

  MonthClose closeOf(DateTime month) => MonthClose(
        id: 'mc-${month.year}-${month.month}',
        ledgerId: lid,
        month: month,
        closedBy: meId,
        closedAt: month,
        details: MonthCloseDetails(month: month, members: const [], sharedDelta: 0),
      );

  group('共同餘額', () {
    test('代墊不動共同餘額，只有共同錢包支出與共同收入會動', () {
      final entries = [
        sharedIncome('i-1', 2000, may(2)),
        wallet('w-1', 500, may(3)),
        advanced('a-1', 1000, may(4)), // 代墊：不進共同餘額
        privateEntry('p-1', 300, may(5), kind: EntryKind.expense, who: meId), // 私人：不進共同餘額
      ];
      expect(sharedBalance(ledger: ledger(10000), entries: entries, until: may31), 11500);
    });

    test('計到 until 當日含：當天的帳算進去、隔天的不算', () {
      final entries = [wallet('w-1', 500, may(10))];
      expect(sharedBalance(ledger: ledger(10000), entries: entries, until: may(9)), 10000);
      expect(sharedBalance(ledger: ledger(10000), entries: entries, until: may(10)), 9500);
    });

    test('occurredOn 帶時間分量時，until 是當日 00:00 也要算進去', () {
      // DB 的 occurred_on 是 date，但前端可能拿到 DateTime.now() 這種帶時間的值；
      // 不先截 date-only 就會漏算當日。
      final entries = [wallet('w-1', 500, DateTime(2026, 5, 10, 13))];
      expect(sharedBalance(ledger: ledger(10000), entries: entries, until: DateTime(2026, 5, 10)),
          9500);
    });

    test('v1.4：預算與清帳都不進共同餘額（同一筆 closes 對個人餘額有效、對共同餘額無效）', () {
      // fixture 刻意混入「會進個人餘額」的私人筆與代墊，這樣清掉 4 月時
      // 個人餘額看得到差異——否則「共同餘額不變」會變成恆真的空斷言。
      final entries = [
        sharedIncome('i-0', 3000, apr(2)),
        wallet('w-0', 800, apr(3)),
        privateEntry('p-apr', 500, apr(4), kind: EntryKind.expense, who: meId),
        advanced('a-apr', 1000, apr(5)), // 未結算代墊：付款人扛全額
        sharedIncome('i-1', 2000, may(2)),
        wallet('w-1', 500, may(3)),
        privateEntry('p-may', 300, may(4), kind: EntryKind.expense, who: meId),
      ];
      final closes = [closeOf(apr1)];
      final me = member(meId, topup: 10000);
      expect(isMonthClosed(closes, apr(15)), isTrue, reason: '4 月確實已清帳');

      // 對照組：同一組帳目，closes 有沒有那一筆，個人餘額差很多……
      final personalOpen = personalBalance(
          member: me,
          entries: entries,
          closes: const [],
          until: may31,
          joinedMonth: apr1,
          today: may31);
      final personalClosed = personalBalance(
          member: me,
          entries: entries,
          closes: closes,
          until: may31,
          joinedMonth: apr1,
          today: may31);
      expect(personalOpen, 18200, reason: '補入額 ×2 ＝20,000 −500 −1,000 −300');
      expect(personalClosed, 9700, reason: '4 月整段移除：補入額 ×1 ＝10,000 −300');

      // ……共同餘額卻兩邊一模一樣（sharedBalance 連 closes 參數都不吃）。
      final shared = sharedBalance(ledger: ledger(10000), entries: entries, until: may31);
      expect(shared, 13700, reason: '10,000 ＋3,000 −800 ＋2,000 −500；代墊與私人筆不進共同');

      // 預算同理：撥再多也不動共同餘額（v1.3 的可用餘額會被預扣，v1.4 不會）。
      final allocations = [alloc('al-1', 99999, may1)];
      expect(totalAllocated(allocations: allocations, month: may31), 99999,
          reason: '預算確實存在，只是不進共同餘額');
      expect(sharedBalance(ledger: ledger(10000), entries: entries, until: may31), shared);
    });
  });

  group('預算（影子紀錄）', () {
    test('allocatedIn：該月那一筆；別的月份、別的分類不算', () {
      final allocations = [
        alloc('al-1', 6000, may1),
        alloc('al-2', 5500, apr1),
        alloc('al-3', 4000, may1, cat: 'c-dining'),
      ];
      expect(allocatedIn(allocations: allocations, categoryId: 'c-food', month: may31), 6000);
      expect(allocatedIn(allocations: allocations, categoryId: 'c-food', month: apr(30)), 5500);
      expect(allocatedIn(allocations: allocations, categoryId: 'c-transport', month: may31), 0);
    });

    test('allocatedIn 不看日序：月中才設定的預算，問月初也算得到', () {
      // 預算是「當月的影子紀錄」，設定當下就對整個月生效（DB 的 alloc CTE 也不篩 occurred_on）。
      final allocations = [alloc('al-1', 6000, may(15))];
      expect(allocatedIn(allocations: allocations, categoryId: 'c-food', month: may1), 6000);
    });

    test('spentIn 含代墊與共同錢包兩種；私人不算；日期照 until 夾', () {
      final entries = [
        wallet('w-1', 1000, may(3)), // 共同錢包
        advanced('a-1', 800, may(6)), // 代墊（payer 非 null）也算
        privateEntry('p-1', 300, may(7), kind: EntryKind.expense, who: meId), // 私人不算
        wallet('w-2', 500, may(20)), // 晚於 until
        wallet('w-3', 400, apr(10)), // 別的月份
        wallet('w-4', 700, may(5), cat: 'c-dining'), // 別的分類
      ];
      expect(spentIn(entries: entries, categoryId: 'c-food', until: may(10)), 1800);
      expect(spentIn(entries: entries, categoryId: 'c-food', until: may31), 2300);
      expect(spentIn(entries: entries, categoryId: 'c-dining', until: may31), 700);
    });

    test('overspend／remainingIn 手算', () {
      final allocations = [alloc('al-1', 2000, may1)];
      final entries = [wallet('w-1', 1200, may(3)), advanced('a-1', 1500, may(6))];
      // 已花 ＝ 1200 ＋ 1500 ＝ 2700；預算 2000 → 超支 700、剩餘 0。
      expect(spentIn(entries: entries, categoryId: 'c-food', until: may31), 2700);
      expect(
          overspend(
              allocations: allocations, entries: entries, categoryId: 'c-food', until: may31),
          700);
      expect(
          remainingIn(
              allocations: allocations, entries: entries, categoryId: 'c-food', until: may31),
          0);

      // 只算到 5/3：已花 1200 → 剩餘 800、不超支。
      expect(
          remainingIn(
              allocations: allocations, entries: entries, categoryId: 'c-food', until: may(3)),
          800);
      expect(
          overspend(
              allocations: allocations, entries: entries, categoryId: 'c-food', until: may(3)),
          0);
    });

    test('budgetCategoryIds／三個合計', () {
      final allocations = [alloc('al-1', 2000, may1), alloc('al-2', 1000, may1, cat: 'c-util')];
      final entries = [
        wallet('w-1', 2700, may(3)), // c-food 超支 700
        wallet('w-2', 500, may(4), cat: 'c-dining'), // 沒預算的分類也算「有活動」
        privateEntry('p-1', 900, may(5), kind: EntryKind.expense, who: meId),
      ];
      expect(
        budgetCategoryIds(allocations: allocations, entries: entries, until: may31),
        {'c-food', 'c-util', 'c-dining'},
      );
      expect(totalAllocated(allocations: allocations, month: may31), 3000);
      expect(totalSpent(entries: entries, until: may31), 3200, reason: '私人筆不算');
      expect(totalOverspend(entries: entries, allocations: allocations, until: may31), 1200,
          reason: 'c-food 700 ＋ c-dining 500');
    });
  });

  group('integerShares（最大餘數法）', () {
    test('567 均分兩人 → 284／283，合計等於主筆金額', () {
      final e = advanced('a-1', 567, may(8));
      final shares = integerShares(e);
      expect(shares[meId], 284, reason: '小數相同時 memberId 序小者先補 1');
      expect(shares[wifeId], 283);
      expect(shares.values.reduce((a, b) => a + b), 567, reason: '逐筆 round() 會變成 568');
    });

    test('三人 100 均分 → 34／33／33', () {
      final e = Entry(
        id: 'a-2',
        ledgerId: lid,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 100,
        categoryId: 'c-food',
        occurredOn: may(9),
        createdBy: meId,
        payerId: meId,
        splitMethod: SplitMethod.equal,
        splits: const [
          EntrySplit(entryId: 'a-2', memberId: 'm-a', share: 33.34),
          EntrySplit(entryId: 'a-2', memberId: 'm-b', share: 33.33),
          EntrySplit(entryId: 'a-2', memberId: 'm-c', share: 33.33),
        ],
      );
      final shares = integerShares(e);
      expect(shares['m-a'], 34);
      expect(shares['m-b'], 33);
      expect(shares['m-c'], 33);
      expect(shares.values.reduce((a, b) => a + b), 100);
    });

    test('沖銷筆（負金額）沿同一條公式：floor 往下、差額補回', () {
      final r = advanced('a-1r', -567, may(8));
      final shares = integerShares(r);
      expect(shares[meId], -283);
      expect(shares[wifeId], -284);
      expect(shares.values.reduce((a, b) => a + b), -567);
    });
  });

  group('isMonthClosed', () {
    test('判準是「月份 ≤ 最大清帳月」，含更早的月份', () {
      final closes = [closeOf(DateTime(2026, 7, 1)), closeOf(DateTime(2026, 8, 1))];
      expect(isMonthClosed(closes, DateTime(2026, 5, 20)), isTrue, reason: '更早的月份也鎖');
      expect(isMonthClosed(closes, DateTime(2026, 7, 1)), isTrue);
      expect(isMonthClosed(closes, DateTime(2026, 8, 31)), isTrue);
      expect(isMonthClosed(closes, DateTime(2026, 9, 1)), isFalse);
    });

    test('沒有清帳紀錄 → 一律未清', () {
      expect(isMonthClosed(const [], may(1)), isFalse);
    });
  });

  group('monthNet（該月淨變動）', () {
    test('私人收支 ＋ 未結算代墊全額 ＋ 已結算份額；共同收入與共同錢包不進', () {
      final entries = [
        privateEntry('p-1', 8000, may(6), kind: EntryKind.income, who: meId),
        privateEntry('p-2', 300, may(7), kind: EntryKind.expense, who: meId),
        privateEntry('p-3', 200, may(8), kind: EntryKind.expense, who: wifeId),
        advanced('a-1', 1000, may(4)), // 未結算代墊：付款人扛全額
        advanced('a-2', 600, may(5), settledState: SettledState.settled), // 已結算：各扛份額
        sharedIncome('i-1', 52000, may(2)), // 共同收入不進
        wallet('w-1', 900, may(3)), // 共同錢包不進
      ];
      expect(
        monthNet(member: member(meId), entries: entries, month: may1),
        8000 - 300 - 1000 - 300,
      );
      expect(monthNet(member: member(wifeId), entries: entries, month: may1), -200 - 300);
    });

    test('結算中（settling）的代墊仍走第 2 段：付款人扛全額', () {
      // DB 的第 2 段是 `settled_state <> 'settled'`，不是 `= 'open'`——
      // 結算發起到簽完之間那段時間，錢還沒搬，付款人照樣扛全額。
      final settling = advanced('a-1', 1000, may(4), settledState: SettledState.settling);
      expect(monthNet(member: member(meId), entries: [settling], month: may1), -1000);
      expect(monthNet(member: member(wifeId), entries: [settling], month: may1), 0);
    });

    test('已結算但 payer 為 null（資料異常形狀）不進個人', () {
      final weird = Entry(
        id: 'x-1',
        ledgerId: lid,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 1000,
        categoryId: 'c-food',
        occurredOn: may(4),
        createdBy: meId,
        splitMethod: SplitMethod.equal,
        settledState: SettledState.settled,
        splits: const [
          EntrySplit(entryId: 'x-1', memberId: meId, share: 500),
          EntrySplit(entryId: 'x-1', memberId: wifeId, share: 500),
        ],
      );
      expect(monthNet(member: member(meId), entries: [weird], month: may1), 0);
      expect(monthNet(member: member(wifeId), entries: [weird], month: may1), 0);
    });

    test('沖銷：原筆＋反向筆的淨變動合計 0', () {
      final origin = advanced('a-1', 567, may(8));
      final reversal = advanced('a-1r', -567, may(9));
      expect(monthNet(member: member(meId), entries: [origin, reversal], month: may1), 0);
      expect(monthNet(member: member(wifeId), entries: [origin, reversal], month: may1), 0);

      // 兩筆都已結算時走份額那條：金額可以整除就一樣抵銷乾淨。
      final so = advanced('a-2', 600, may(8), settledState: SettledState.settled);
      final sr = advanced('a-2r', -600, may(9), settledState: SettledState.settled);
      expect(monthNet(member: member(meId), entries: [so, sr], month: may1), 0);
      expect(monthNet(member: member(wifeId), entries: [so, sr], month: may1), 0);

      // 金額除不盡且**兩筆都已結算**時，最大餘數法的那 1 元補在正負兩邊的同一個人身上
      // （tie-break 都是 memberId 序小者），所以逐人會各差 1 元、全體才歸零。
      // 這是 DB `entry_member_effects` 的同一條公式，前後端一致——不是這裡算錯。
      // 實務上沖銷筆是新插入的，一律 open（`entries_force_open_on_insert`），
      // 走的是上面那條全額回退，不會踩到這個殘差。
      final oo = advanced('a-3', 567, may(8), settledState: SettledState.settled);
      final orv = advanced('a-3r', -567, may(9), settledState: SettledState.settled);
      final perMember = [
        monthNet(member: member(meId), entries: [oo, orv], month: may1),
        monthNet(member: member(wifeId), entries: [oo, orv], month: may1),
      ];
      expect(perMember.reduce((a, b) => a + b), 0);
      expect(perMember, [-1, 1]);
    });

    test('until 給了就再夾一次日期', () {
      final entries = [privateEntry('p-1', 300, may(20), kind: EntryKind.expense, who: meId)];
      expect(monthNet(member: member(meId), entries: entries, month: may1), -300);
      expect(monthNet(member: member(meId), entries: entries, month: may1, until: may(10)), 0);
    });
  });

  group('個人餘額（額度制）', () {
    // 固定 fixture，與 `supabase/tests/month_summary.sql` 的 m1 同一組數字：
    // 補入額 10,000、私人支出 300、代墊 1,000 均分。
    final privateExpense = privateEntry('p-1', 300, may(7), kind: EntryKind.expense, who: meId);

    test('未結算代墊：付款人扛全額 → 8,700', () {
      final entries = [privateExpense, advanced('a-1', 1000, may(4))];
      expect(
        personalBalance(
          member: member(meId, topup: 10000),
          entries: entries,
          closes: const [],
          until: may31,
          joinedMonth: may1,
          today: may31,
        ),
        8700,
      );
    });

    test('結算後改扛自己的份額 → 9,200；對方補入額 8,000 → 7,500', () {
      final entries = [
        privateExpense,
        advanced('a-1', 1000, may(4), settledState: SettledState.settled),
      ];
      expect(
        personalBalance(
          member: member(meId, topup: 10000),
          entries: entries,
          closes: const [],
          until: may31,
          joinedMonth: may1,
          today: may31,
        ),
        9200,
      );
      expect(
        personalBalance(
          member: member(wifeId, topup: 8000),
          entries: entries,
          closes: const [],
          until: may31,
          joinedMonth: may1,
          today: may31,
        ),
        7500,
      );
    });

    test('兩個月：上月淨變動 −10,200、本月無帳 → 9,800；清掉上月 → 10,000', () {
      // 4 月：私人支出 200 ＋ 未結算代墊 10,000 ＝ −10,200；5 月沒有任何帳目。
      final entries = [
        privateEntry('p-apr', 200, apr(3), kind: EntryKind.expense, who: meId),
        advanced('a-apr', 10000, apr(10)),
      ];
      expect(monthNet(member: member(meId), entries: entries, month: apr1), -10200);

      final me = member(meId, topup: 10000);
      expect(
        personalBalance(
          member: me,
          entries: entries,
          closes: const [],
          until: may31,
          joinedMonth: apr1,
          today: may31,
        ),
        9800,
        reason: '補入額 ×2 ＝ 20,000，減掉上月的 10,200',
      );
      expect(
        personalBalance(
          member: me,
          entries: entries,
          closes: [closeOf(apr1)],
          until: may31,
          joinedMonth: apr1,
          today: may31,
        ),
        10000,
        reason: '清完上月，那個月的補入額與淨變動一起自公式移除',
      );
    });

    test('已清帳＝月份 ≤ 最後清帳月：人工救援挖掉中間列，06 照樣被排除', () {
      // closes 只有 07、08（06 那列被人在雲端 SQL 刪掉了）。
      // 判準是「≤ max(closes.month)」而不是「有沒有那一列」，所以 06 仍然算已清帳：
      // 06 的帳目不進餘額、06 也不算補入額。否則 06 會偷偷回到餘額裡，
      // 而鎖月 trigger 照樣擋著改不動，餘額永遠對不平。
      final closes = [closeOf(DateTime(2026, 7, 1)), closeOf(DateTime(2026, 8, 1))];
      final juneExpense =
          privateEntry('p-jun', 1000, DateTime(2026, 6, 10), kind: EntryKind.expense, who: meId);
      final sepExpense =
          privateEntry('p-sep', 300, DateTime(2026, 9, 3), kind: EntryKind.expense, who: meId);
      final me = member(meId, topup: 10000);
      final until = DateTime(2026, 9, 30);

      expect(isMonthClosed(closes, DateTime(2026, 6, 10)), isTrue, reason: '06 ≤ max(08)');
      expect(
        personalBalance(
          member: me,
          entries: [juneExpense, sepExpense],
          closes: closes,
          until: until,
          joinedMonth: DateTime(2026, 6, 1),
          today: until,
        ),
        9700,
        reason: '只剩 09 一個月：補入額 10,000 − 09 的私人支出 300；06 那筆與 06 的補入額都被排除',
      );
    });

    test('N：加入月晚於 until 所在月 → 0；2026-06 加入、until 2026-09-30、無 closes → N=4', () {
      final me = member(meId, topup: 10000);
      expect(
        personalBalance(
          member: me,
          entries: const [],
          closes: const [],
          until: apr(30),
          joinedMonth: may1,
          today: may31,
        ),
        0,
        reason: '還沒加入那幾個月不該先補錢',
      );
      expect(
        personalBalance(
          member: me,
          entries: const [],
          closes: const [],
          until: may31,
          joinedMonth: mar1,
          today: may31,
        ),
        30000,
        reason: '3、4、5 三個月各補一次',
      );
      // 兩端含（與 DB 的 generate_series 同）：06、07、08、09 ＝ 4 個月。
      expect(
        personalBalance(
          member: me,
          entries: const [],
          closes: const [],
          until: DateTime(2026, 9, 30),
          joinedMonth: DateTime(2026, 6, 1),
          today: DateTime(2026, 9, 30),
        ),
        40000,
        reason: 'N=4',
      );
    });

    test('已 settled 但 payer 為 null 的筆不進個人餘額', () {
      final weird = Entry(
        id: 'x-1',
        ledgerId: lid,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 1000,
        categoryId: 'c-food',
        occurredOn: may(4),
        createdBy: meId,
        splitMethod: SplitMethod.equal,
        settledState: SettledState.settled,
        splits: const [
          EntrySplit(entryId: 'x-1', memberId: meId, share: 500),
          EntrySplit(entryId: 'x-1', memberId: wifeId, share: 500),
        ],
      );
      expect(
        personalBalance(
          member: member(meId, topup: 10000),
          entries: [weird],
          closes: const [],
          until: may31,
          joinedMonth: may1,
          today: may31,
        ),
        10000,
      );
    });

    test('沖銷筆讓個人餘額回到原點', () {
      final entries = [
        advanced('a-1', 567, may(8)),
        advanced('a-1r', -567, may(9)),
      ];
      expect(
        personalBalance(
          member: member(meId, topup: 10000),
          entries: entries,
          closes: const [],
          until: may31,
          joinedMonth: may1,
          today: may31,
        ),
        10000,
      );
    });

    test('期初個人餘額 v1.4 起完全不入公式', () {
      final legacy = Member(
        id: meId,
        ledgerId: lid,
        userId: 'u',
        displayName: 'Mike',
        monthlyTopup: 10000,
        openingBalancePersonal: 50000,
        joinedAt: DateTime(1970),
      );
      expect(
        personalBalance(
          member: legacy,
          entries: const [],
          closes: const [],
          until: may31,
          joinedMonth: may1,
          today: may31,
        ),
        10000,
      );
    });

    test('未清帳月份的帳目照算、已清月份整段移除', () {
      final entries = [
        privateEntry('p-apr', 200, apr(3), kind: EntryKind.expense, who: meId),
        privateEntry('p-may', 300, may(3), kind: EntryKind.expense, who: meId),
      ];
      final me = member(meId, topup: 0);
      expect(
        personalBalance(
            member: me,
            entries: entries,
            closes: const [],
            until: may31,
            joinedMonth: apr1,
            today: may31),
        -500,
      );
      expect(
        personalBalance(
            member: me,
            entries: entries,
            closes: [closeOf(apr1)],
            until: may31,
            joinedMonth: apr1,
            today: may31),
        -300,
      );
    });
  });

  group('日期工具', () {
    test('monthOf／sameMonth／prevMonth／nextMonth', () {
      expect(monthOf(may(17)), may1);
      expect(sameMonth(may(1), may(31)), isTrue);
      expect(sameMonth(apr(30), may(1)), isFalse);
      expect(prevMonth(may1), apr1);
      expect(nextMonth(may1), DateTime(2026, 6, 1));
    });
  });

  group('myPortion', () {
    test('私人全額只算本人；共同 common 依 ratio；有 splits 取 splits', () {
      final priv = privateEntry('p-1', 350, may(7), kind: EntryKind.expense, who: meId);
      expect(myPortion(priv, meId, const {meId: 50, wifeId: 50}), 350);
      expect(myPortion(priv, wifeId, const {meId: 50, wifeId: 50}), 0);

      final common = wallet('w-1', 1000, may(3));
      expect(myPortion(common, meId, const {meId: 50, wifeId: 50}), 500);

      final split = advanced('a-1', 1000, may(4));
      expect(myPortion(split, wifeId, const {meId: 50, wifeId: 50}), 500);
    });

    test('共同收入不進個人視角（進共同餘額，與 personalBalance 一致）', () {
      final salary = sharedIncome('i-1', 100000, may(5));
      expect(myPortion(salary, meId, const {meId: 50, wifeId: 50}), 0);
      expect(myPortion(salary, wifeId, const {meId: 50, wifeId: 50}), 0);
    });
  });
}
