import 'package:accounting/domain/balance_math.dart';
import 'package:accounting/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 錢公式（spec v1.5「餘額、補入與預算」／ADR-0009）。每條規則一段獨立 fixture：
/// 一段只讓一條規則生效，避免互相遮蔽。日期全部寫死在**過去**（2026-03～2026-05），
/// 不吃 `DateTime.now()`。
void main() {
  const lid = 'l';
  const meId = 'm-a';
  const wifeId = 'm-b';

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
        amount: amount,
        categoryId: cat,
        occurredOn: on,
        createdBy: meId,
      );

  /// 某位成員先付的支出。
  Entry paidBy(
    String id,
    int amount,
    DateTime on, {
    String payer = meId,
    String cat = 'c-food',
    bool isAdjustment = false,
  }) =>
      Entry(
        id: id,
        ledgerId: lid,
        kind: EntryKind.expense,
        amount: amount,
        categoryId: cat,
        occurredOn: on,
        createdBy: payer,
        payerId: payer,
        isAdjustment: isAdjustment,
      );

  Entry income(String id, int amount, DateTime on) => Entry(
        id: id,
        ledgerId: lid,
        kind: EntryKind.income,
        amount: amount,
        categoryId: 'c-salary',
        occurredOn: on,
        createdBy: meId,
      );

  PersonalTopup topup(String id, String memberId, int amount, DateTime on) => PersonalTopup(
        id: id,
        ledgerId: lid,
        memberId: memberId,
        amount: amount,
        occurredOn: on,
        createdBy: memberId,
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
        details: MonthCloseDetails(month: month, members: const [], sharedPaid: 0),
      );

  group('共同餘額', () {
    test('只有共同收入與共同錢包支出會動它；成員先付的不動', () {
      final entries = [
        income('i-1', 20000, may(5)),
        wallet('w-1', 3000, may(3)),
        paidBy('p-1', 6000, may(8)), // 我先付：扣的是我的補入剩餘，不是共同餘額
        paidBy('p-2', 2000, may(9), payer: wifeId),
      ];
      expect(sharedBalance(entries: entries, until: may31), 17000);
    });

    test('v1.5 沒有期初：一本沒有任何帳目的帳本，共同餘額是 0', () {
      expect(sharedBalance(entries: const [], until: may31), 0);
    });

    test('計到 until 當日含：當天的帳算進去、隔天的不算', () {
      final entries = [wallet('w-1', 500, may(10))];
      expect(sharedBalance(entries: entries, until: may(9)), 0);
      expect(sharedBalance(entries: entries, until: may(10)), -500);
    });

    test('occurredOn 帶時間分量時，until 是當日 00:00 也要算進去', () {
      final entries = [wallet('w-1', 500, DateTime(2026, 5, 10, 23, 59))];
      expect(sharedBalance(entries: entries, until: may(10)), -500);
    });

    test('跨月累計：共同餘額是水位，不是當月淨額', () {
      final entries = [
        income('i-1', 20000, apr(5)),
        wallet('w-1', 20000, apr(1)),
        income('i-2', 20000, may(5)),
        wallet('w-2', 3000, may(3)),
      ];
      expect(sharedBalance(entries: entries, until: may31), 17000);
    });

    test('補入與清帳都不進共同餘額', () {
      final entries = [income('i-1', 20000, may(5)), wallet('w-1', 3000, may(3))];
      // 補入再多也不會讓共同帳戶多一塊錢（那是各自口袋裡的錢）。
      expect(sharedBalance(entries: entries, until: may31), 17000);
      expect(topupIn(topups: [topup('t-1', meId, 99999, may1)], memberId: meId, month: may1), 99999);
      expect(sharedBalance(entries: entries, until: may31), 17000);
    });
  });

  group('個人補入剩餘（每人每月）', () {
    final topups = [
      topup('t-1', meId, 10000, may1),
      topup('t-2', wifeId, 10000, may(2)),
      topup('t-3', meId, 8000, apr1), // 上月的不進本月
    ];
    final entries = [
      income('i-1', 20000, may(5)),
      wallet('w-1', 3000, may(3)), // 共同錢包：不進任何人
      paidBy('p-1', 6000, may(8)),
      paidBy('p-2', 2000, may(9), payer: wifeId),
      paidBy('p-3', 1200, apr(10)), // 上月的不進本月
    ];

    test('spec 驗收資料集：Mike 10,000／6,000 → 4,000；老婆 10,000／2,000 → 8,000', () {
      expect(topupIn(topups: topups, memberId: meId, month: may1), 10000);
      expect(paidIn(entries: entries, memberId: meId, month: may1), 6000);
      expect(topupRemaining(topups: topups, entries: entries, memberId: meId, month: may1), 4000);

      expect(topupIn(topups: topups, memberId: wifeId, month: may1), 10000);
      expect(paidIn(entries: entries, memberId: wifeId, month: may1), 2000);
      expect(topupRemaining(topups: topups, entries: entries, memberId: wifeId, month: may1), 8000);
    });

    test('同月多筆補入相加；別的月份不算', () {
      final many = [
        topup('t-1', meId, 6000, may(1)),
        topup('t-2', meId, 4000, may(20)),
        topup('t-3', meId, 5000, apr(1)),
      ];
      expect(topupIn(topups: many, memberId: meId, month: may1), 10000);
      expect(topupIn(topups: many, memberId: meId, month: apr1), 5000);
      expect(topupIn(topups: many, memberId: wifeId, month: may1), 0);
    });

    test('paidIn 只算本人先付的支出：共同錢包、別人先付、收入都不算', () {
      expect(
        paidIn(entries: [
          wallet('w-1', 3000, may(3)),
          paidBy('p-1', 6000, may(8)),
          paidBy('p-2', 2000, may(9), payer: wifeId),
          income('i-1', 20000, may(5)),
        ], memberId: meId, month: may1),
        6000,
      );
    });

    test('paidIn 把沖銷的負數筆算進去（漏掉的話剩餘永遠停在沖銷前）', () {
      final withReversal = [
        paidBy('p-1', 6000, may(8)),
        paidBy('p-1r', -6000, may(8), isAdjustment: true),
        paidBy('p-2', 500, may(9)),
      ];
      expect(paidIn(entries: withReversal, memberId: meId, month: may1), 500);
      expect(
        topupRemaining(
            topups: [topup('t-1', meId, 10000, may1)],
            entries: withReversal,
            memberId: meId,
            month: may1),
        9500,
      );
    });

    test('剩餘可為負：先付超過補入不夾 0', () {
      expect(
        topupRemaining(
          topups: [topup('t-1', meId, 1000, may1)],
          entries: [paidBy('p-1', 4000, may(8))],
          memberId: meId,
          month: may1,
        ),
        -3000,
      );
    });

    test('沒有補入也沒有先付 → 0', () {
      expect(topupRemaining(topups: const [], entries: const [], memberId: meId, month: may1), 0);
    });
  });

  group('sharedPaidIn（清帳明細的對照欄）', () {
    test('只算該月共同錢包付掉的支出；成員先付與收入都不算', () {
      final entries = [
        wallet('w-1', 3000, may(3)),
        wallet('w-2', 500, apr(3)),
        paidBy('p-1', 6000, may(8)),
        income('i-1', 20000, may(5)),
      ];
      expect(sharedPaidIn(entries: entries, month: may1), 3000);
      expect(sharedPaidIn(entries: entries, month: apr1), 500);
      expect(sharedPaidIn(entries: entries, month: mar1), 0);
    });
  });

  group('預算（影子紀錄）', () {
    test('allocatedIn：該月那一筆；別的月份、別的分類不算', () {
      final allocs = [
        alloc('a-1', 6000, may1),
        alloc('a-2', 5000, apr1),
        alloc('a-3', 4000, may1, cat: 'c-dining'),
      ];
      expect(allocatedIn(allocations: allocs, categoryId: 'c-food', month: may1), 6000);
      expect(allocatedIn(allocations: allocs, categoryId: 'c-food', month: apr1), 5000);
      expect(allocatedIn(allocations: allocs, categoryId: 'c-daily', month: may1), 0);
    });

    test('allocatedIn 不看日序：月中才設定的預算，問月初也算得到', () {
      final allocs = [alloc('a-1', 6000, may(20))];
      expect(allocatedIn(allocations: allocs, categoryId: 'c-food', month: may(1)), 6000);
    });

    test('spentIn 含「誰先付」與共同錢包兩種；日期照 until 夾', () {
      final entries = [
        wallet('w-1', 1000, may(3)),
        paidBy('p-1', 2000, may(8)),
        paidBy('p-2', 500, may(20), payer: wifeId),
        paidBy('p-3', 900, apr(8)), // 別的月
        income('i-1', 20000, may(5)), // 收入不是支出
      ];
      expect(spentIn(entries: entries, categoryId: 'c-food', until: may31), 3500);
      expect(spentIn(entries: entries, categoryId: 'c-food', until: may(8)), 3000);
      expect(spentIn(entries: entries, categoryId: 'c-food', until: may(2)), 0);
    });

    test('overspend／remainingIn 手算', () {
      final allocs = [alloc('a-1', 6000, may1)];
      final entries = [wallet('w-1', 4000, may(3)), paidBy('p-1', 3500, may(8))];
      expect(spentIn(entries: entries, categoryId: 'c-food', until: may31), 7500);
      expect(
          remainingIn(
              allocations: allocs, entries: entries, categoryId: 'c-food', until: may31),
          0,
          reason: '剩餘夾在 0');
      expect(
          overspend(allocations: allocs, entries: entries, categoryId: 'c-food', until: may31),
          1500);
    });

    test('沒設預算的分類：剩餘 0、超支＝已花', () {
      final entries = [wallet('w-1', 800, may(3), cat: 'c-fun')];
      expect(
          remainingIn(
              allocations: const [], entries: entries, categoryId: 'c-fun', until: may31),
          0);
      expect(
          overspend(allocations: const [], entries: entries, categoryId: 'c-fun', until: may31),
          800);
    });

    test('budgetCategoryIds／三個合計', () {
      final allocs = [alloc('a-1', 6000, may1), alloc('a-2', 4000, may1, cat: 'c-dining')];
      final entries = [
        wallet('w-1', 7500, may(3)),
        paidBy('p-1', 2000, may(8), cat: 'c-dining'),
        wallet('w-2', 300, may(9), cat: 'c-fun'),
        income('i-1', 20000, may(5)),
      ];
      expect(budgetCategoryIds(allocations: allocs, entries: entries, until: may31),
          {'c-food', 'c-dining', 'c-fun'});
      expect(totalAllocated(allocations: allocs, month: may1), 10000);
      expect(totalSpent(entries: entries, until: may31), 9800);
      // c-food 超 1500；c-dining 沒超；c-fun 沒預算 → 超 300。
      expect(totalOverspend(entries: entries, allocations: allocs, until: may31), 1800);
    });

    test('totalSpent 不分誰付，收入不算', () {
      final entries = [
        wallet('w-1', 3000, may(3)),
        paidBy('p-1', 6000, may(8)),
        paidBy('p-2', 2000, may(9), payer: wifeId),
        income('i-1', 20000, may(5)),
      ];
      expect(totalSpent(entries: entries, until: may31), 11000);
    });
  });

  group('isMonthClosed', () {
    test('判準是「月份 ≤ 最大清帳月」，含更早的月份', () {
      final closes = [closeOf(apr1)];
      expect(isMonthClosed(closes, mar1), isTrue);
      expect(isMonthClosed(closes, apr(20)), isTrue);
      expect(isMonthClosed(closes, may(1)), isFalse);
    });

    test('人工救援挖掉中間列，仍以最大清帳月為準', () {
      // 03 那列被刪掉、只剩 04：03 照樣算已清（不然那些帳目會突然又能改）。
      final closes = [closeOf(apr1)];
      expect(isMonthClosed(closes, mar1), isTrue);
    });

    test('沒有清帳紀錄 → 一律未清', () {
      expect(isMonthClosed(const [], mar1), isFalse);
      expect(isMonthClosed(const [], may31), isFalse);
    });
  });

  group('日期工具', () {
    test('monthOf／sameMonth／prevMonth／nextMonth', () {
      expect(monthOf(may(18)), may1);
      expect(sameMonth(may(1), may(31)), isTrue);
      expect(sameMonth(may(31), DateTime(2026, 6, 1)), isFalse);
      expect(prevMonth(may1), apr1);
      expect(nextMonth(DateTime(2026, 12, 1)), DateTime(2027, 1, 1));
      expect(prevMonth(DateTime(2026, 1, 1)), DateTime(2025, 12, 1));
    });
  });
}
