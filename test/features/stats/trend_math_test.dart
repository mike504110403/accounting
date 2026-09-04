import 'package:accounting/domain/balance_math.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/stats/trend_math.dart';
import 'package:accounting/features/stats/view_math.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定小資料集（不吃 DateTime.now()），每個顆粒度的桶數與數值都寫死期望值。
///
/// 帳目（全部共同錢包）：3/1 收入 10000、3/5 支出 500＋200、3/12 支出 1000、2/10 支出 800。共同期初 0。
/// v1.3 起餘額與超支不再由分桶自己算，改由 [TrendInput.balanceAt]／[TrendInput.overspendAt]
/// 兩個「算到某日」的函式供給；這裡把家庭視角的真函式接上去，驗的是「桶末日餵對了」。
void main() {
  const c1 = Category(
      id: 'c1', ledgerId: 'l', kind: EntryKind.expense, name: '食品', icon: 'restaurant', sort: 0);
  const cIncome = Category(
      id: 'i1', ledgerId: 'l', kind: EntryKind.income, name: '薪水', icon: 'payments', sort: 0);

  const ledger = Ledger(
    id: 'l',
    name: '我們的家',
    inviteCode: 'A7K3QZ',
    defaultRatio: {'m': 100},
    openingBalanceShared: 0,
  );

  Entry exp(String id, int amt, DateTime on, [String cat = 'c1']) => Entry(
        id: id,
        ledgerId: 'l',
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: amt,
        categoryId: cat,
        occurredOn: on,
        createdBy: 'm',
      );

  final entries = <Entry>[
    Entry(
      id: 'i-1',
      ledgerId: 'l',
      kind: EntryKind.income,
      scope: EntryScope.shared,
      amount: 10000,
      categoryId: 'i1',
      occurredOn: DateTime(2026, 3, 1),
      createdBy: 'm',
    ),
    exp('e-1', 500, DateTime(2026, 3, 5)),
    exp('e-2', 200, DateTime(2026, 3, 5)),
    exp('e-3', 1000, DateTime(2026, 3, 12)),
    exp('e-4', 800, DateTime(2026, 2, 10)),
  ];

  /// 家庭視角的輸入：餘額＝共同餘額（v1.4 不再預扣預算）、超支＝當月超支合計。
  TrendInput familyInput(
    List<Entry> es, {
    List<BudgetAllocation> allocations = const [],
    List<Category> categories = const [c1, cIncome],
  }) =>
      TrendInput(
        items: viewEntries(es, ViewMode.family, 'm', const {'m': 100}),
        categories: categories,
        balanceAt: (until) => sharedBalance(ledger: ledger, entries: es, until: until),
        overspendAt: (until) =>
            totalOverspend(entries: es, allocations: allocations, until: until),
        categoryOverspendAt: (categoryId, until) => overspend(
          allocations: allocations,
          entries: es,
          categoryId: categoryId,
          until: until,
        ),
      );

  final input = familyInput(entries);
  final anchor = DateTime(2026, 3, 1);

  test('日顆粒度：當月每日一桶', () {
    final b = bucketize(input, Granularity.day, anchor);
    expect(b.length, 31);
    expect(b.first.label, '1');
    expect(b.last.label, '31');
    expect(b.first.start, DateTime(2026, 3, 1));
    expect(b.last.end, DateTime(2026, 3, 31));

    // 3/1：無支出，收入 10000，2/10 已花 800
    expect(b[0].spend, 0);
    expect(b[0].over, 0);
    expect(b[0].balance, 9200);

    // 3/5：兩筆合計 700
    expect(b[4].spend, 700);
    expect(b[4].balance, 8500);

    // 3/12：1000
    expect(b[11].spend, 1000);
    expect(b[11].balance, 7500);

    // 月底無新帳，餘額持平
    expect(b.last.spend, 0);
    expect(b.last.balance, 7500);
  });

  test('週顆粒度：最近 12 週', () {
    final w = bucketize(input, Granularity.week, anchor);
    expect(w.length, 12);
    // 3/31 是週二 → 最後一桶為 3/30 那週；往前 11 週 = 1/12
    expect(w.last.start, DateTime(2026, 3, 30));
    expect(w.last.end, DateTime(2026, 4, 5));
    expect(w.last.label, '3/30');
    expect(w.first.start, DateTime(2026, 1, 12));
    expect(w.first.label, '1/12');
    expect(w.last.spend, 0);

    final wk = w.firstWhere((x) => x.start == DateTime(2026, 3, 2));
    expect(wk.spend, 700);
    expect(wk.balance, 8500);

    final wk2 = w.firstWhere((x) => x.start == DateTime(2026, 3, 9));
    expect(wk2.spend, 1000);
    expect(wk2.balance, 7500);

    expect(w.first.spend, 0);
    expect(w.first.balance, 0);
  });

  test('月顆粒度：最近 12 個月', () {
    final m = bucketize(input, Granularity.month, anchor);
    expect(m.length, 12);
    expect(m.first.start, DateTime(2025, 4, 1));
    expect(m.last.start, DateTime(2026, 3, 1));
    expect(m.last.end, DateTime(2026, 3, 31));
    expect(m.last.label, '3月');
    expect(m.first.label, '4月');

    expect(m.last.spend, 1700);
    // v1.4：超支＝max(0, 已花 − 預算)，沒設預算就是預算 0 → 已花全額都算超支
    //（v1.3 只算「從信封出」的那種支出，所以這裡以前是 0）。
    expect(m.last.over, 1700);
    expect(m.last.balance, 7500);

    final feb = m.firstWhere((x) => x.start == DateTime(2026, 2, 1));
    expect(feb.spend, 800);
    expect(feb.balance, -800);

    final dec = m.firstWhere((x) => x.start == DateTime(2025, 12, 1));
    expect(dec.spend, 0);
    expect(dec.balance, 0);
  });

  test('年顆粒度：最近 5 年', () {
    final y = bucketize(input, Granularity.year, anchor);
    expect(y.length, 5);
    expect(y.map((b) => b.label).toList(), ['2022', '2023', '2024', '2025', '2026']);
    expect(y.last.start, DateTime(2026, 1, 1));
    expect(y.last.end, DateTime(2026, 12, 31));

    expect(y.last.spend, 2500); // 800 + 1700
    expect(y.last.balance, 7500);
    expect(y[3].spend, 0);
  });

  test('餘額／超支一律以桶末日（含）為 until', () {
    final seen = <DateTime>[];
    final probe = TrendInput(
      items: const [],
      categories: const [c1],
      balanceAt: (until) {
        seen.add(until);
        return 0;
      },
      overspendAt: (_) => 0,
      categoryOverspendAt: (_, _) => 0,
    );
    final m = bucketize(probe, Granularity.month, anchor);
    expect(seen, [for (final b in m) b.end]);
    expect(seen.last, DateTime(2026, 3, 31));
  });

  test('超支線吃 totalOverspend：預算 1000、3 月已花 3200 → 超支 2200', () {
    final es = [
      ...entries,
      Entry(
        id: 'b-1',
        ledgerId: 'l',
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 1500,
        categoryId: 'c1',
        occurredOn: DateTime(2026, 3, 20),
        createdBy: 'm',
      ),
    ];
    final allocations = [
      BudgetAllocation(
          id: 'al-1',
          ledgerId: 'l',
          categoryId: 'c1',
          amount: 1000,
          occurredOn: DateTime(2026, 3, 1),
          createdBy: 'm'),
    ];
    final m = bucketize(familyInput(es, allocations: allocations), Granularity.month, anchor);
    // 3 月花費含這筆 1500 → 已花 3200、預算 1000 → 超支 2200
    expect(m.last.spend, 3200);
    expect(m.last.over, 2200);
    // 2 月只有一筆 800、沒有預算 → 超支 800（預算不跨月，3 月那筆撥款不會回頭蓋 2 月）
    expect(m.firstWhere((x) => x.start == DateTime(2026, 2, 1)).over, 800);
  });

  test('家庭趨勢餘額線＝sharedBalance：不吃 allocations，撥款再多也不變（v1.3 會變、v1.4 不會）', () {
    final withoutAlloc = bucketize(familyInput(entries), Granularity.month, anchor);
    final withAlloc = bucketize(
      familyInput(entries, allocations: [
        BudgetAllocation(
            id: 'al-x',
            ledgerId: 'l',
            categoryId: 'c1',
            amount: 999999,
            occurredOn: DateTime(2026, 3, 1),
            createdBy: 'm'),
      ]),
      Granularity.month,
      anchor,
    );
    for (var i = 0; i < withoutAlloc.length; i++) {
      expect(withAlloc[i].balance, withoutAlloc[i].balance, reason: '第 $i 桶');
    }
    // 手算對照沿用上面「月顆粒度：最近 12 個月」測試的算式：本月桶末＝7500
    expect(withAlloc.last.balance, 7500);
  });

  test('超支計入代墊（v1.4）：payer 非 null、非 common 的共同支出照樣算已花（v1.3 不計）', () {
    final advance = Entry(
      id: 'adv-1',
      ledgerId: 'l',
      kind: EntryKind.expense,
      scope: EntryScope.shared,
      amount: 1000,
      categoryId: 'c1',
      occurredOn: DateTime(2026, 3, 8),
      createdBy: 'm',
      payerId: 'm',
      splitMethod: SplitMethod.equal,
      splits: const [
        EntrySplit(entryId: 'adv-1', memberId: 'm', share: 500),
        EntrySplit(entryId: 'adv-1', memberId: 'w', share: 500),
      ],
    );
    final allocations = [
      BudgetAllocation(
          id: 'al-2',
          ledgerId: 'l',
          categoryId: 'c1',
          amount: 500,
          occurredOn: DateTime(2026, 3, 1),
          createdBy: 'm'),
    ];
    final m = bucketize(
      familyInput([...entries, advance], allocations: allocations),
      Granularity.month,
      anchor,
    );
    // 3 月已花：原本 1700（500+200+1000）＋代墊 1000＝2700；預算 500 → 超支 2200
    // （v1.3 只算從共同錢包出的支出，代墊 1000 不會進已花，超支只會是 1200）。
    expect(m.last.spend, 2700);
    expect(m.last.over, 2200);
  });

  test('個人視角：桶內金額用我的份額、超支恆 0', () {
    final shared = [
      Entry(
        id: 's-1',
        ledgerId: 'l',
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 1000,
        categoryId: 'c1',
        occurredOn: DateTime(2026, 3, 4),
        createdBy: 'm',
        payerId: 'm',
        splitMethod: SplitMethod.equal,
        splits: const [
          EntrySplit(entryId: 's-1', memberId: 'm', share: 500),
          EntrySplit(entryId: 's-1', memberId: 'w', share: 500),
        ],
      ),
    ];
    // v1.4：個人餘額＝每月補入額 × 未清帳月份數 ＋ 淨變動（期初個人餘額已廢用）。
    final me = Member(
        id: 'm',
        ledgerId: 'l',
        userId: 'u',
        displayName: 'Mike',
        monthlyTopup: 1000,
        joinedAt: DateTime(2026, 3, 1),
      );
    final in3 = TrendInput(
      items: viewEntries(shared, ViewMode.personal, 'm', const {'m': 50, 'w': 50}),
      categories: const [c1],
      // 個人視角：個人餘額（代墊當下扣全額）、沒有預算所以超支恆 0
      // `today` 釘死在固定資料集的月份內，不吃 `DateTime.now()`——這條測試的其他
      // 日期全是寫死的 2026-03，若不釘 today，本檔案在真正的 2026-03 之前執行會因為
      // 「今天所在月」把 N 的上界拉到比 2026-03 更早而變成別的答案。
      balanceAt: (until) => personalBalance(
        member: me,
        entries: shared,
        closes: const [],
        until: until,
        joinedMonth: DateTime(2026, 3, 1),
        today: DateTime(2026, 3, 31),
      ),
      overspendAt: (_) => 0,
      categoryOverspendAt: (_, _) => 0,
    );
    final m = bucketize(in3, Granularity.month, anchor);
    expect(m.last.spend, 500, reason: '花費是我的份額');
    expect(m.last.balance, 0, reason: '3 月補入額 1000 − 代墊全額 1000');
    expect(m.last.over, 0);
  });

  test('個人餘額純函式手算：與 stats_page_test.dart「closes 含上月」widget 測試同一組 fixture 對得起來', () {
    // stats_page_test.dart 那條 widget 測試因為 flutter_riverpod 的 ProviderScope
    // 在同一顆 tree 上重複 pumpWidget 會重用既有 container（見該檔案的說明），
    // 沒辦法在同一條測試裡先驗「清帳前」再驗「清帳後」，只能把「清帳前應該是
    // 多少」寫死在註解當手算依據。這裡直接呼叫 personalBalance 這個純函式，把
    // 700／1550 這兩個數字釘死成真正被驗證過的事實，不是註解裡的空話。
    final lastMonth = DateTime(2026, 2, 1);
    final thisMonth = DateTime(2026, 3, 1);
    final me = Member(
      id: 'm',
      ledgerId: 'l',
      userId: 'u',
      displayName: 'Mike',
      monthlyTopup: 1000,
      joinedAt: lastMonth, // 加入月＝上月，N=1 的邊界情況（見 stats_page_test.dart 註解）
    );
    final entries = [
      Entry(
        id: 'ce-1',
        ledgerId: 'l',
        kind: EntryKind.expense,
        scope: EntryScope.private,
        amount: 300,
        categoryId: 'c1',
        occurredOn: DateTime(lastMonth.year, lastMonth.month, 10),
        createdBy: 'm',
        payerId: 'm',
      ),
      Entry(
        id: 'ce-2',
        ledgerId: 'l',
        kind: EntryKind.expense,
        scope: EntryScope.private,
        amount: 150,
        categoryId: 'c1',
        occurredOn: DateTime(thisMonth.year, thisMonth.month, 10),
        createdBy: 'm',
        payerId: 'm',
      ),
    ];

    // 上月（加入月，N=1）：補入額 1000 − 私人支出 300 ＝ 700。
    expect(
      personalBalance(
        member: me,
        entries: entries,
        closes: const [],
        until: DateTime(lastMonth.year, lastMonth.month + 1, 0),
        joinedMonth: lastMonth,
        today: thisMonth,
      ),
      700,
    );
    // 本月（N=2，累計）：補入額 1000×2 − 300 − 150 ＝ 1550。
    expect(
      personalBalance(
        member: me,
        entries: entries,
        closes: const [],
        until: DateTime(thisMonth.year, thisMonth.month + 1, 0),
        joinedMonth: lastMonth,
        today: thisMonth,
      ),
      1550,
    );
  });

  group('bucketizeByCategory', () {
    const c2 = Category(
        id: 'c2', ledgerId: 'l', kind: EntryKind.expense, name: '交通', icon: 'x', sort: 1);
    final es = [
      ...entries,
      exp('t-1', 300, DateTime(2026, 3, 5), 'c2'),
      exp('t-2', 100, DateTime(2026, 2, 20), 'c2'),
    ];
    final in2 = familyInput(es, categories: const [c1, c2, cIncome]);

    test('每個支出分類一組桶，收入分類不出現', () {
      final m = bucketizeByCategory(in2, Granularity.month, anchor);
      expect(m.keys.toSet(), {'c1', 'c2'});
      expect(m.containsKey('i1'), isFalse, reason: '收入分類沒有花費線');
      expect(m['c1']!.length, 12);
      expect(m['c1']!.last.label, '3月');
      expect(m['c1']!.last.start, DateTime(2026, 3, 1));
    });

    test('花費只收自己分類的帳', () {
      final m = bucketizeByCategory(in2, Granularity.month, anchor);
      expect(m['c1']!.last.spend, 1700);
      expect(m['c1']!.firstWhere((b) => b.start == DateTime(2026, 2, 1)).spend, 800);
      expect(m['c2']!.last.spend, 300);
      expect(m['c2']!.firstWhere((b) => b.start == DateTime(2026, 2, 1)).spend, 100);
      final all = bucketize(in2, Granularity.month, anchor);
      expect(m['c1']!.last.spend + m['c2']!.last.spend, all.last.spend);
    });

    test('balance 一律 null：分類沒有餘額概念，跟「算出來是 0」區分開', () {
      for (final g in Granularity.values) {
        final m = bucketizeByCategory(in2, g, anchor);
        for (final list in m.values) {
          expect(list.every((b) => b.balance == null), isTrue, reason: '$g');
        }
      }
    });

    test('over 是該分類自己的超支，不是帳本合計', () {
      // c1 預算 1000、3 月已花 3200 → 超支 2200；c2 沒預算、已花 300 → 超支 300
      final es = [
        ...entries,
        Entry(
          id: 'b-1',
          ledgerId: 'l',
          kind: EntryKind.expense,
          scope: EntryScope.shared,
          amount: 1500,
          categoryId: 'c1',
          occurredOn: DateTime(2026, 3, 20),
          createdBy: 'm',
        ),
        exp('t-1', 300, DateTime(2026, 3, 5), 'c2'),
      ];
      final allocations = [
        BudgetAllocation(
            id: 'al-1',
            ledgerId: 'l',
            categoryId: 'c1',
            amount: 1000,
            occurredOn: DateTime(2026, 3, 1),
            createdBy: 'm'),
      ];
      final in3 = familyInput(es, allocations: allocations, categories: const [c1, c2, cIncome]);
      final m = bucketizeByCategory(in3, Granularity.month, anchor);
      // c1：已花 3200 − 預算 1000 ＝ 2200；c2：已花 300、沒預算 → 全額算超支
      expect(m['c1']!.last.over, 2200);
      expect(m['c2']!.last.over, 300);
      // 帳本合計是兩者相加，但那是總覽桶的事，分類桶各算各的
      expect(bucketize(in3, Granularity.month, anchor).last.over, 2500);
    });

    test('四種顆粒度的桶數與總覽一致', () {
      const expected = {
        Granularity.day: 31,
        Granularity.week: 12,
        Granularity.month: 12,
        Granularity.year: 5,
      };
      expected.forEach((g, n) {
        final m = bucketizeByCategory(in2, g, anchor);
        expect(m['c1']!.length, n, reason: '$g');
        expect(bucketize(in2, g, anchor).length, n, reason: '$g 總覽');
      });
    });

    test('日顆粒度：花費落在正確的日桶', () {
      final m = bucketizeByCategory(in2, Granularity.day, anchor);
      expect(m['c1']![4].spend, 700);
      expect(m['c2']![4].spend, 300);
    });
  });
}
