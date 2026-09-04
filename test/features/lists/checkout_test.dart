import 'package:accounting/domain/models.dart';
import 'package:accounting/features/lists/checkout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const l1 = ListItem(id: 'l1', ledgerId: 'ledger', title: '酸奶', store: '超市', estimated: 120, categoryId: 'c-food');
  const l2 = ListItem(id: 'l2', ledgerId: 'ledger', title: '麵包', store: '超市', estimated: 80, categoryId: 'c-food');
  const l3 = ListItem(id: 'l3', ledgerId: 'ledger', title: '衛生紙', store: '藥局', estimated: 199, categoryId: 'c-daily', sort: 1);
  const l4 = ListItem(id: 'l4', ledgerId: 'ledger', title: '運動鞋', estimated: 2500, categoryId: 'c-daily', sort: 0);

  group('groupByStore', () {
    test('依 store 分組，null 併入未分店家、組內依 sort 排序', () {
      final groups = groupByStore([l1, l2, l3, l4]);
      expect(groups.keys.toList(), ['藥局', '超市', kNoStoreLabel]);
      expect(groups['超市']!.map((e) => e.id), ['l1', 'l2']);
      expect(groups[kNoStoreLabel]!.single.id, 'l4');
    });

    test('未分店家固定排最後', () {
      final groups = groupByStore([l4, l1]);
      expect(groups.keys.last, kNoStoreLabel);
    });
  });

  group('buildEntryFromItems', () {
    final date = DateTime(2026, 9, 2);

    const me = Member(id: 'm-1', ledgerId: 'ledger', userId: 'u1', displayName: 'Mike');
    const wife = Member(id: 'm-2', ledgerId: 'ledger', userId: 'u2', displayName: '老婆');

    test('結帳方式：成員代墊＋均分 → payer/splits/method 正確、funding 一律 balance', () {
      final entry = buildEntryFromItems(
        items: [l1, l2],
        actuals: {'l1': 100, 'l2': 100},
        total: 200,
        categoryId: 'c-food',
        date: date,
        ledgerId: 'ledger',
        me: 'm-1',
        allocations: [
          // 該月有撥款：若 funding 沒被強制 balance，這裡會誤判成 budget
          BudgetAllocation(id: 'a1', ledgerId: 'ledger', categoryId: 'c-food', amount: 1000, occurredOn: date, createdBy: 'm-1'),
        ],
        payerId: 'm-1',
        splitMethod: SplitMethod.equal,
        members: const [me, wife],
      );
      expect(entry.payerId, 'm-1');
      expect(entry.splitMethod, SplitMethod.equal);
      expect(entry.funding, Funding.balance, reason: '代墊不可走預算（Entry 不變式）');
      expect(entry.splits.length, 2);
      expect(entry.splits.map((s) => s.share).reduce((a, b) => a + b), 200);
    });

    test('結帳方式：金額分攤用 manual 值', () {
      final entry = buildEntryFromItems(
        items: [l1],
        actuals: {'l1': 300},
        total: 300,
        categoryId: 'c-food',
        date: date,
        ledgerId: 'ledger',
        me: 'm-1',
        allocations: const [],
        payerId: 'm-2',
        splitMethod: SplitMethod.amount,
        members: const [me, wife],
        manual: const {'m-1': 120, 'm-2': 180},
      );
      expect(entry.splits.firstWhere((s) => s.memberId == 'm-1').share, 120);
      expect(entry.splits.firstWhere((s) => s.memberId == 'm-2').share, 180);
    });

    test('結帳方式：共同錢包可指定 funding（覆蓋 defaultFunding）', () {
      final entry = buildEntryFromItems(
        items: [l1],
        actuals: {'l1': 100},
        total: 100,
        categoryId: 'c-food',
        date: date,
        ledgerId: 'ledger',
        me: 'm-1',
        allocations: const [], // 無撥款 → default 是 balance
        funding: Funding.budget, // 但 DB check 擋不擋是後端的事；這裡驗參數會被帶上
      );
      expect(entry.payerId, isNull);
      expect(entry.splitMethod, SplitMethod.common);
      expect(entry.funding, Funding.budget);
      expect(entry.splits, isEmpty);
    });

    test('組裝共同支出：金額用 actuals，缺項回退 estimated，note 用店家名', () {
      final entry = buildEntryFromItems(
        items: [l1, l2],
        actuals: {'l1': 100},
        total: 180,
        categoryId: 'c-food',
        date: date,
        ledgerId: 'ledger',
        me: 'm-mike',
        allocations: const [],
      );
      expect(entry.kind, EntryKind.expense);
      expect(entry.scope, EntryScope.shared);
      expect(entry.payerId, isNull);
      expect(entry.splitMethod, SplitMethod.common);
      expect(entry.amount, 180);
      expect(entry.categoryId, 'c-food');
      expect(entry.occurredOn, date);
      expect(entry.createdBy, 'm-mike');
      expect(entry.note, '超市');
      expect(entry.lineItems.length, 2);
      expect(entry.lineItems[0].name, '酸奶');
      expect(entry.lineItems[0].amount, 100); // 有填 actuals
      expect(entry.lineItems[1].name, '麵包');
      expect(entry.lineItems[1].amount, 80); // 沒填回退 estimated
      expect(entry.lineItems.every((li) => li.entryId == entry.id), isTrue);
    });

    test('沒有店家的項目 note 回退「購物」', () {
      final entry = buildEntryFromItems(
        items: [l4],
        actuals: const {},
        total: 2500,
        categoryId: 'c-daily',
        date: date,
        ledgerId: 'ledger',
        me: 'm-mike',
        allocations: const [],
      );
      expect(entry.note, '購物');
    });

    test('actuals 與 estimated 都缺時細項金額為 0', () {
      const bare = ListItem(id: 'l5', ledgerId: 'ledger', title: '未知項目', categoryId: 'c-daily');
      final entry = buildEntryFromItems(
        items: [bare],
        actuals: const {},
        total: 0,
        categoryId: 'c-daily',
        date: date,
        ledgerId: 'ledger',
        me: 'm-mike',
        allocations: const [],
      );
      expect(entry.lineItems.single.amount, 0);
    });

    test('分類本月有撥款 → funding=budget', () {
      final allocations = [
        BudgetAllocation(id: 'a-1', ledgerId: 'ledger', categoryId: 'c-food', amount: 3000, occurredOn: DateTime(2026, 9, 1), createdBy: 'm-mike'),
      ];
      final entry = buildEntryFromItems(
        items: [l1, l2],
        actuals: {'l1': 100},
        total: 180,
        categoryId: 'c-food',
        date: date,
        ledgerId: 'ledger',
        me: 'm-mike',
        allocations: allocations,
      );
      expect(entry.funding, Funding.budget);
    });

    test('分類本月無撥款 → funding=balance', () {
      final allocations = [
        BudgetAllocation(id: 'a-1', ledgerId: 'ledger', categoryId: 'c-daily', amount: 3000, occurredOn: DateTime(2026, 9, 1), createdBy: 'm-mike'),
      ];
      final entry = buildEntryFromItems(
        items: [l1, l2],
        actuals: {'l1': 100},
        total: 180,
        categoryId: 'c-food',
        date: date,
        ledgerId: 'ledger',
        me: 'm-mike',
        allocations: allocations,
      );
      expect(entry.funding, Funding.balance);
    });
  });

  group('withDone / markItemsDone', () {
    test('withDone 只改 doneAt／entryId，其餘欄位保留', () {
      final now = DateTime(2026, 9, 2, 10);
      final done = withDone(l1, now, entryId: 'e-1');
      expect(done.doneAt, now);
      expect(done.entryId, 'e-1');
      expect(done.title, l1.title);
      expect(done.store, l1.store);
      expect(done.estimated, l1.estimated);
      expect(done.isDone, isTrue);
    });

    test('markItemsDone 整批標成同一筆 entry', () {
      final now = DateTime(2026, 9, 2, 10);
      final result = markItemsDone([l1, l2], 'e-9', now);
      expect(result.every((i) => i.entryId == 'e-9' && i.doneAt == now), isTrue);
    });
  });

  group('resolveDoneAmount', () {
    test('唯一匹配名稱 → 直接回細項金額', () {
      final entry = Entry(
        id: 'e-1',
        ledgerId: 'ledger',
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 120,
        categoryId: 'c-food',
        occurredOn: DateTime(2026, 9, 2),
        createdBy: 'm-mike',
        lineItems: const [LineItem(id: 'li-1', entryId: 'e-1', name: '酸奶', amount: 120, sort: 0)],
      );
      final done = withDone(l1, DateTime(2026, 9, 2), entryId: 'e-1');
      expect(resolveDoneAmount(done, [entry], [done]), 120);
    });

    test('entryId 找不到對應 entry → 回退 estimated', () {
      final done = withDone(l1, DateTime(2026, 9, 2), entryId: 'e-missing');
      expect(resolveDoneAmount(done, const [], [done]), l1.estimated);
    });

    test('同一筆 entry 下同名項目：ListItem 依 id 排名對 LineItem 依 sort 排名（現行近似對應規則，非保證精確）', () {
      final eggA = ListItem(id: 'a-egg', ledgerId: 'ledger', title: '雞蛋', categoryId: 'c-food', entryId: 'e-2', doneAt: DateTime(2026, 9, 2));
      final eggB = ListItem(id: 'b-egg', ledgerId: 'ledger', title: '雞蛋', categoryId: 'c-food', entryId: 'e-2', doneAt: DateTime(2026, 9, 2));
      final entry = Entry(
        id: 'e-2',
        ledgerId: 'ledger',
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 120,
        categoryId: 'c-food',
        occurredOn: DateTime(2026, 9, 2),
        createdBy: 'm-mike',
        lineItems: const [
          LineItem(id: 'li-1', entryId: 'e-2', name: '雞蛋', amount: 50, sort: 0),
          LineItem(id: 'li-2', entryId: 'e-2', name: '雞蛋', amount: 70, sort: 1),
        ],
      );
      final allItems = [eggA, eggB];
      // 'a-egg' < 'b-egg' → eggA 排名 0 對 sort=0（50）、eggB 排名 1 對 sort=1（70）。
      expect(resolveDoneAmount(eggA, [entry], allItems), 50);
      expect(resolveDoneAmount(eggB, [entry], allItems), 70);
    });
  });
}
