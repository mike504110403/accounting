import 'package:accounting/domain/balance_math.dart';
import 'package:accounting/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 每條規則一段獨立 fixture：一段只讓一條規則生效，避免互相遮蔽。
/// 日期全部寫死（2026-04／2026-05），不吃 `DateTime.now()`。
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

  Member member(String id, int opening) =>
      Member(id: id, ledgerId: lid, userId: 'u-$id', displayName: id, openingBalancePersonal: opening);

  final may1 = DateTime(2026, 5, 1);
  final may31 = DateTime(2026, 5, 31);
  final apr1 = DateTime(2026, 4, 1);
  final apr30 = DateTime(2026, 4, 30);
  DateTime may(int d) => DateTime(2026, 5, d);
  DateTime apr(int d) => DateTime(2026, 4, d);

  /// 共同錢包支出（payer 為 null）。
  Entry wallet(String id, int amount, DateTime on, {String cat = 'c-food', Funding funding = Funding.balance}) => Entry(
        id: id,
        ledgerId: lid,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: amount,
        categoryId: cat,
        occurredOn: on,
        createdBy: meId,
        funding: funding,
      );

  /// 代墊：付款人是成員，均分兩人。
  Entry advanced(String id, int amount, DateTime on, {String payer = meId, String cat = 'c-food'}) => Entry(
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

  Entry privateEntry(String id, int amount, DateTime on, {required EntryKind kind, required String who}) => Entry(
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
      BudgetAllocation(id: id, ledgerId: lid, categoryId: cat, amount: amount, occurredOn: on, createdBy: meId);

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
      // 不先截 date-only 就會漏算當日（舊 runningBalance 的既有雷）。
      final entries = [wallet('w-1', 500, DateTime(2026, 5, 10, 13))];
      expect(sharedBalance(ledger: ledger(10000), entries: entries, until: DateTime(2026, 5, 10)), 9500);
    });
  });

  group('信封與可用餘額', () {
    test('撥款當下就從可用餘額預扣，共同餘額不動', () {
      final allocations = [alloc('al-1', 3000, may1)];
      expect(sharedBalance(ledger: ledger(10000), entries: const [], until: may31), 10000);
      expect(
        envelopeRemaining(allocations: allocations, entries: const [], categoryId: 'c-food', until: may31),
        3000,
      );
      expect(
        sharedAvailable(ledger: ledger(10000), entries: const [], allocations: allocations, until: may31),
        7000,
      );
    });

    test('預算支出扣信封，可用餘額不動', () {
      final allocations = [alloc('al-1', 3000, may1)];
      final entries = [wallet('w-1', 1000, may(10), funding: Funding.budget)];
      expect(
        envelopeRemaining(allocations: allocations, entries: entries, categoryId: 'c-food', until: may31),
        2000,
      );
      expect(overspend(allocations: allocations, entries: entries, categoryId: 'c-food', until: may31), 0);
      expect(sharedBalance(ledger: ledger(10000), entries: entries, until: may31), 9000);
      // 9000 − 信封剩餘 2000
      expect(
        sharedAvailable(ledger: ledger(10000), entries: entries, allocations: allocations, until: may31),
        7000,
      );
    });

    test('超額變超支，剩餘 clamp 0 且可用餘額同步被扣', () {
      final allocations = [alloc('al-1', 3000, may1)];
      final entries = [
        wallet('w-1', 1000, may(10), funding: Funding.budget),
        wallet('w-2', 2500, may(12), funding: Funding.budget),
      ];
      expect(budgetSpentIn(entries: entries, categoryId: 'c-food', until: may31), 3500);
      expect(
        envelopeRemaining(allocations: allocations, entries: entries, categoryId: 'c-food', until: may31),
        0,
        reason: '剩餘不得為負',
      );
      expect(overspend(allocations: allocations, entries: entries, categoryId: 'c-food', until: may31), 500);
      expect(totalOverspend(entries: entries, allocations: allocations, until: may31), 500);
      // 未超支時可用餘額是 7000；超支 500 之後可用餘額同步降到 6500
      expect(
        sharedAvailable(ledger: ledger(10000), entries: entries, allocations: allocations, until: may31),
        6500,
      );
    });

    test('補撥即回補超支', () {
      final entries = [
        wallet('w-1', 1000, may(10), funding: Funding.budget),
        wallet('w-2', 2500, may(12), funding: Funding.budget),
      ];
      final after = [alloc('al-1', 3000, may1), alloc('al-2', 500, may(13))];
      expect(allocatedIn(allocations: after, categoryId: 'c-food', until: may31), 3500);
      expect(overspend(allocations: after, entries: entries, categoryId: 'c-food', until: may31), 0);
      expect(envelopeRemaining(allocations: after, entries: entries, categoryId: 'c-food', until: may31), 0);
      // 錢真的花掉了，可用餘額停在 6500（回補的是超支，不是錢）
      expect(sharedAvailable(ledger: ledger(10000), entries: entries, allocations: after, until: may31), 6500);
    });

    test('退回（負撥款）把信封還回可用餘額', () {
      final allocations = [alloc('al-1', 3000, may1), alloc('al-2', -1200, may(20))];
      expect(allocatedIn(allocations: allocations, categoryId: 'c-food', until: may31), 1800);
      expect(sharedAvailable(ledger: ledger(10000), entries: const [], allocations: allocations, until: may31), 8200);
    });

    test('代墊與 funding=balance 的共同支出都不吃信封', () {
      final allocations = [alloc('al-1', 3000, may1)];
      final entries = [
        wallet('w-1', 800, may(6)), // funding 預設 balance
        advanced('a-1', 900, may(7)),
      ];
      expect(budgetSpentIn(entries: entries, categoryId: 'c-food', until: may31), 0);
      expect(envelopeRemaining(allocations: allocations, entries: entries, categoryId: 'c-food', until: may31), 3000);
      // 共同餘額 10000 − 800（代墊不扣）＝ 9200；可用餘額再扣信封 3000
      expect(sharedAvailable(ledger: ledger(10000), entries: entries, allocations: allocations, until: may31), 6200);
    });

    test('上月剩餘不跨月：4 月撥款不進 5 月信封', () {
      final allocations = [alloc('al-1', 5000, apr1)];
      expect(allocatedIn(allocations: allocations, categoryId: 'c-food', until: apr30), 5000);
      expect(allocatedIn(allocations: allocations, categoryId: 'c-food', until: may31), 0);
      expect(envelopeRemaining(allocations: allocations, entries: const [], categoryId: 'c-food', until: may31), 0);
      // 5 月沒有任何信封 → 可用餘額＝共同餘額
      expect(sharedAvailable(ledger: ledger(10000), entries: const [], allocations: allocations, until: may31), 10000);
    });

    test('上月超支不跨月：4 月超支 2000 不帶進 5 月', () {
      final allocations = [alloc('al-1', 1000, apr1)];
      final entries = [wallet('w-1', 3000, apr(10), funding: Funding.budget)];
      expect(totalOverspend(entries: entries, allocations: allocations, until: apr30), 2000);
      expect(totalOverspend(entries: entries, allocations: allocations, until: may31), 0);
      // 5 月可用餘額只剩「錢真的少了 3000」，不再扣上月的超支
      expect(sharedAvailable(ledger: ledger(10000), entries: entries, allocations: allocations, until: may31), 7000);
    });

    test('同月但晚於 until 的撥款不算（allocatedIn 的 until 邊界）', () {
      final allocations = [alloc('al-1', 3000, may(5)), alloc('al-2', 4000, may(15))];
      // until = 5/10：只算 5/5 那筆
      expect(allocatedIn(allocations: allocations, categoryId: 'c-food', until: may(10)), 3000);
      expect(envelopeRemaining(allocations: allocations, entries: const [], categoryId: 'c-food', until: may(10)), 3000);
      expect(sharedAvailable(ledger: ledger(10000), entries: const [], allocations: allocations, until: may(10)), 7000);
      // 當日含：until = 5/15 就算進去
      expect(allocatedIn(allocations: allocations, categoryId: 'c-food', until: may(15)), 7000);
    });

    test('同月但晚於 until 的預算支出不算（budgetSpentIn 的 until 邊界）', () {
      final allocations = [alloc('al-1', 3000, may1)];
      final entries = [
        wallet('w-1', 500, may(5), funding: Funding.budget),
        wallet('w-2', 900, may(15), funding: Funding.budget),
      ];
      // until = 5/10：只算 5/5 那筆
      expect(budgetSpentIn(entries: entries, categoryId: 'c-food', until: may(10)), 500);
      expect(envelopeRemaining(allocations: allocations, entries: entries, categoryId: 'c-food', until: may(10)), 2500);
      // 當日含：until = 5/15 兩筆都算
      expect(budgetSpentIn(entries: entries, categoryId: 'c-food', until: may(15)), 1400);
      expect(envelopeRemaining(allocations: allocations, entries: entries, categoryId: 'c-food', until: may(15)), 1600);
    });

    test('沒撥款就用預算付：全額算超支', () {
      final entries = [wallet('w-1', 700, may(9), funding: Funding.budget)];
      expect(overspend(allocations: const [], entries: entries, categoryId: 'c-food', until: may31), 700);
      expect(totalOverspend(entries: entries, allocations: const [], until: may31), 700);
    });

    test('信封與超支跨分類各自結算，不互相抵銷', () {
      final allocations = [alloc('al-1', 3000, may1), alloc('al-2', 500, may1, cat: 'c-dining')];
      final entries = [
        wallet('w-1', 1000, may(10), funding: Funding.budget),
        wallet('w-2', 1200, may(11), cat: 'c-dining', funding: Funding.budget),
      ];
      expect(totalEnvelopeRemaining(entries: entries, allocations: allocations, until: may31), 2000);
      expect(totalOverspend(entries: entries, allocations: allocations, until: may31), 700);
      // 共同餘額 10000 − 2200 ＝ 7800，再扣信封剩餘 2000
      expect(sharedAvailable(ledger: ledger(10000), entries: entries, allocations: allocations, until: may31), 5800);
    });
  });

  group('個人餘額', () {
    // 手算樣本（brief §2）：Mike 期初 0，代墊 1,000 均分兩人。
    final adv = advanced('a-1', 1000, may(4));
    final settled = Settlement(
      id: 's-1',
      ledgerId: lid,
      status: SettlementStatus.settled,
      initiatedBy: wifeId,
      createdAt: DateTime(2026, 5, 18, 9),
      settledAt: DateTime(2026, 5, 20, 10),
      nets: const {meId: 500, wifeId: -500},
      entryIds: const ['a-1'],
      approvedBy: const {meId},
    );

    test('代墊當日：付款人扣全額、對方不動、共同餘額不動', () {
      expect(
        personalBalance(member: member(meId, 0), entries: [adv], settlements: const [], until: may(4)),
        -1000,
      );
      expect(
        personalBalance(member: member(wifeId, 0), entries: [adv], settlements: const [], until: may(4)),
        0,
      );
      expect(sharedBalance(ledger: ledger(10000), entries: [adv], until: may31), 10000);
    });

    test('結算 settled 那天起，兩人各自負擔自己的份額', () {
      expect(
        personalBalance(member: member(meId, 0), entries: [adv], settlements: [settled], until: may(20)),
        -500,
      );
      expect(
        personalBalance(member: member(wifeId, 0), entries: [adv], settlements: [settled], until: may(20)),
        -500,
      );
      expect(sharedBalance(ledger: ledger(10000), entries: [adv], until: may(20)), 10000);
    });

    test('settledAt 晚於 until 就不算', () {
      expect(
        personalBalance(member: member(meId, 0), entries: [adv], settlements: [settled], until: may(19)),
        -1000,
      );
      expect(
        personalBalance(member: member(wifeId, 0), entries: [adv], settlements: [settled], until: may(19)),
        0,
      );
    });

    test('未 settled 的結算不算（pending 不搬錢）', () {
      final pending = Settlement(
        id: 's-2',
        ledgerId: lid,
        status: SettlementStatus.pending,
        initiatedBy: wifeId,
        createdAt: DateTime(2026, 5, 18, 9),
        settledAt: DateTime(2026, 5, 20, 10),
        nets: const {meId: 500, wifeId: -500},
        entryIds: const ['a-1'],
        approvedBy: const {},
      );
      expect(
        personalBalance(member: member(meId, 0), entries: [adv], settlements: [pending], until: may31),
        -1000,
      );
    });

    test('私人收支只動本人；共同收入不進個人餘額', () {
      final entries = [
        privateEntry('p-1', 8000, may(6), kind: EntryKind.income, who: meId),
        privateEntry('p-2', 350, may(7), kind: EntryKind.expense, who: meId),
        privateEntry('p-3', 200, may(8), kind: EntryKind.expense, who: wifeId),
        sharedIncome('i-1', 52000, may(5)),
      ];
      expect(
        personalBalance(member: member(meId, 1000), entries: entries, settlements: const [], until: may31),
        1000 + 8000 - 350,
      );
      expect(
        personalBalance(member: member(wifeId, 0), entries: entries, settlements: const [], until: may31),
        -200,
      );
    });

    test('私人支出的 payerId 是本人，只能扣一次（不得同時走代墊那條）', () {
      // seed e-8（Steam 350）就是這個形狀：scope=private、createdBy=payerId=本人。
      final e = privateEntry('p-1', 350, may(7), kind: EntryKind.expense, who: meId);
      expect(e.payerId, meId, reason: '私人筆的 payer 固定是本人');
      expect(
        personalBalance(member: member(meId, 1000), entries: [e], settlements: const [], until: may31),
        650,
        reason: '1000 − 350，不是 1000 − 700',
      );
    });

    test('個人可用餘額＝個人餘額（個人沒有信封）', () {
      expect(
        personalAvailable(member: member(meId, 0), entries: [adv], settlements: [settled], until: may(20)),
        personalBalance(member: member(meId, 0), entries: [adv], settlements: [settled], until: may(20)),
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

  group('defaultFunding', () {
    test('該月有撥款 → budget', () {
      final allocations = [alloc('al-1', 3000, may1)];
      expect(defaultFunding(allocations: allocations, categoryId: 'c-food', month: may(15)), Funding.budget);
    });

    test('該月無撥款 → balance', () {
      expect(defaultFunding(allocations: const [], categoryId: 'c-food', month: may(15)), Funding.balance);
    });

    test('撥款合計 ≤0（退回抵消）→ balance', () {
      final allocations = [alloc('al-1', 3000, may1), alloc('al-2', -3000, may(20))];
      expect(defaultFunding(allocations: allocations, categoryId: 'c-food', month: may(15)), Funding.balance);
    });

    test('別的月份撥款不算', () {
      final allocations = [alloc('al-1', 3000, apr1)];
      expect(defaultFunding(allocations: allocations, categoryId: 'c-food', month: may(15)), Funding.balance);
    });

    test('不同分類的撥款不算', () {
      final allocations = [alloc('al-1', 3000, may1, cat: 'c-dining')];
      expect(defaultFunding(allocations: allocations, categoryId: 'c-food', month: may(15)), Funding.balance);
    });

    test('撥款日非月初（15 號）也算：只看月份，不看撥款當月的日序', () {
      final allocations = [alloc('al-1', 3000, may(15))];
      // month 傳月初（1 號），撥款卻在 15 號：若誤用 allocatedIn 的 until 語意
      // （until=1 號會把 15 號那筆擋在外面）就會漏算，這裡釘住不會。
      expect(defaultFunding(allocations: allocations, categoryId: 'c-food', month: may1), Funding.budget);
      // 反過來，month 傳月中、撥款在月初，一樣要算。
      expect(defaultFunding(allocations: allocations, categoryId: 'c-food', month: may(3)), Funding.budget);
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
      expect(myPortion(salary, meId, const {meId: 100}), 0);
    });
  });
}
