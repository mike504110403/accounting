import 'package:accounting/domain/models.dart';
import 'package:accounting/features/stats/trend_math.dart';
import 'package:accounting/features/stats/view_math.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定小資料集（不吃 DateTime.now()），每個顆粒度的桶數與數值都寫死期望值。
///
/// 分類 c1（expense，不 rollover），2026-01 起上限 3100：
///   2026-03 有 31 天 → 日預算 100；2026-04 有 30 天 → 日預算 103.333…
/// 帳目：3/1 收入 10000、3/5 支出 500＋200、3/12 支出 1000、2/10 支出 800。期初 0。
void main() {
  const c1 = Category(
      id: 'c1', ledgerId: 'l', kind: EntryKind.expense, name: '食品', icon: 'restaurant', sort: 0);
  const cIncome = Category(
      id: 'i1', ledgerId: 'l', kind: EntryKind.income, name: '薪水', icon: 'payments', sort: 0);

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

  final budgets = [
    Budget(id: 'b1', ledgerId: 'l', categoryId: 'c1', month: DateTime(2026, 1, 1), limit: 3100),
  ];

  final input = TrendInput(
    items: viewEntries(entries, ViewMode.family, 'm', const {'m': 100}),
    categories: const [c1, cIncome],
    budgets: budgets,
    rolloverBasis: entries,
    opening: 0,
  );
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
    expect(b[0].budget, 100);
    expect(b[0].over, 0);
    expect(b[0].balance, 9200);

    // 3/5：兩筆合計 700，日預算 100 → 超支 600
    expect(b[4].spend, 700);
    expect(b[4].budget, 100);
    expect(b[4].over, 600);
    expect(b[4].balance, 8500);

    // 3/12：1000
    expect(b[11].spend, 1000);
    expect(b[11].over, 900);
    expect(b[11].balance, 7500);

    // 月底無新帳，餘額持平
    expect(b.last.spend, 0);
    expect(b.last.balance, 7500);
  });

  test('週顆粒度：最近 12 週、跨月週的預算按各月天數攤', () {
    final w = bucketize(input, Granularity.week, anchor);
    expect(w.length, 12);
    // 3/31 是週二 → 最後一桶為 3/30 那週；往前 11 週 = 1/12
    expect(w.last.start, DateTime(2026, 3, 30));
    expect(w.last.end, DateTime(2026, 4, 5));
    expect(w.last.label, '3/30');
    expect(w.first.start, DateTime(2026, 1, 12));
    expect(w.first.label, '1/12');

    // 3/30、3/31 各 100 ＋ 4/1–4/5 各 3100/30 → 200 + 516.67 ≈ 717
    expect(w.last.budget, 717);
    expect(w.last.spend, 0);

    final wk = w.firstWhere((x) => x.start == DateTime(2026, 3, 2));
    expect(wk.spend, 700);
    expect(wk.budget, 700);
    expect(wk.over, 0);
    expect(wk.balance, 8500);

    final wk2 = w.firstWhere((x) => x.start == DateTime(2026, 3, 9));
    expect(wk2.spend, 1000);
    expect(wk2.budget, 700);
    expect(wk2.over, 300);
    expect(wk2.balance, 7500);

    // 1 月起上限 3100、1 月 31 天 → 日 100，整週 7×100
    expect(w.first.budget, 700);
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
    expect(m.last.budget, 3100);
    expect(m.last.over, 0);
    expect(m.last.balance, 7500);

    final feb = m.firstWhere((x) => x.start == DateTime(2026, 2, 1));
    expect(feb.spend, 800);
    expect(feb.budget, 3100);
    expect(feb.over, 0);
    expect(feb.balance, -800);

    // 預算起點前：沒預算算 0
    final dec = m.firstWhere((x) => x.start == DateTime(2025, 12, 1));
    expect(dec.spend, 0);
    expect(dec.budget, 0);
    expect(dec.balance, 0);
  });

  test('年顆粒度：最近 5 年，預算＝該年 12 個月加總', () {
    final y = bucketize(input, Granularity.year, anchor);
    expect(y.length, 5);
    expect(y.map((b) => b.label).toList(), ['2022', '2023', '2024', '2025', '2026']);
    expect(y.last.start, DateTime(2026, 1, 1));
    expect(y.last.end, DateTime(2026, 12, 31));

    expect(y.last.spend, 2500); // 800 + 1700
    expect(y.last.budget, 3100 * 12);
    expect(y.last.over, 0);
    expect(y.last.balance, 7500);

    expect(y[3].budget, 0); // 2025 無預算
    expect(y[3].spend, 0);
  });

  test('超支＝max(0, 花費−預算)，不會出現負值', () {
    final b = bucketize(input, Granularity.day, anchor);
    expect(b.every((x) => x.over >= 0), isTrue);
    expect(b.every((x) => x.over == (x.spend - x.budget > 0 ? x.spend - x.budget : 0)), isTrue);
  });

  test('預算線吃 effectiveLimit：rollover 分類把上月結餘帶進來', () {
    const roll = Category(
        id: 'c2',
        ledgerId: 'l',
        kind: EntryKind.expense,
        name: '日用品',
        icon: 'inventory_2',
        sort: 1,
        rollover: true);
    final bs = [
      Budget(id: 'b2', ledgerId: 'l', categoryId: 'c2', month: DateTime(2026, 1, 1), limit: 3000),
    ];
    final es = [exp('r-1', 1000, DateTime(2026, 1, 10), 'c2')];
    final in2 = TrendInput(
      items: viewEntries(es, ViewMode.family, 'm', const {'m': 100}),
      categories: const [roll],
      budgets: bs,
      rolloverBasis: es,
      opening: 0,
    );
    final m = bucketize(in2, Granularity.month, DateTime(2026, 2, 1));
    // 1 月上限 3000 花 1000 → 2 月有效上限 3000 + 2000 = 5000
    expect(m.last.budget, 5000);
    expect(m.firstWhere((x) => x.start == DateTime(2026, 1, 1)).budget, 3000);
  });

  test('個人視角：預算線按 defaultRatio 折算，與花費線同口徑', () {
    // 同一份資料改看個人視角（皆 common split → 份額各半），budgetShare 0.5
    final personal = TrendInput(
      items: viewEntries(entries, ViewMode.personal, 'm', const {'m': 50, 'w': 50}),
      categories: const [c1, cIncome],
      budgets: budgets,
      rolloverBasis: entries,
      opening: 0,
      budgetShare: 0.5,
    );

    final m = bucketize(personal, Granularity.month, anchor);
    // 上限 3100 折半 → 1550；花費 (500+200+1000)/2 = 850
    expect(m.last.budget, 1550);
    expect(m.last.spend, 850);
    expect(m.last.over, 0);
    // 期初 0 ＋ 收入 5000 − 2 月 400 − 3 月 850
    expect(m.last.balance, 3750);

    // 日桶：1550/31 = 50
    final d = bucketize(personal, Granularity.day, anchor);
    expect(d[0].budget, 50);
    // 3/5 花 350 vs 日預算 50 → 超支 300（家庭視角同日是 700 vs 100 → 600）
    expect(d[4].spend, 350);
    expect(d[4].over, 300);

    // 週桶 3/2–3/8：7×50
    final w = bucketize(personal, Granularity.week, anchor);
    expect(w.firstWhere((x) => x.start == DateTime(2026, 3, 2)).budget, 350);

    // 年桶：12×1550
    final y = bucketize(personal, Granularity.year, anchor);
    expect(y.last.budget, 18600);

    // 家庭視角不受影響（budgetShare 預設 1.0）
    expect(bucketize(input, Granularity.month, anchor).last.budget, 3100);
  });

  group('bucketizeByCategory', () {
    const c2 = Category(
        id: 'c2', ledgerId: 'l', kind: EntryKind.expense, name: '交通', icon: 'x', sort: 1);
    final es = [
      ...entries,
      exp('t-1', 300, DateTime(2026, 3, 5), 'c2'),
      exp('t-2', 100, DateTime(2026, 2, 20), 'c2'),
    ];
    final in2 = TrendInput(
      items: viewEntries(es, ViewMode.family, 'm', const {'m': 100}),
      categories: const [c1, c2, cIncome],
      budgets: budgets,
      rolloverBasis: es,
      opening: 0,
    );

    test('每個支出分類一組桶，收入分類不出現', () {
      final m = bucketizeByCategory(in2, Granularity.month, anchor);
      expect(m.keys.toSet(), {'c1', 'c2'});
      expect(m.containsKey('i1'), isFalse, reason: '收入分類沒有花費線');
      // 桶的範圍與 bucketize 一致
      expect(m['c1']!.length, 12);
      expect(m['c1']!.last.label, '3月');
      expect(m['c1']!.last.start, DateTime(2026, 3, 1));
    });

    test('花費只收自己分類的帳', () {
      final m = bucketizeByCategory(in2, Granularity.month, anchor);
      // c1：3 月 500+200+1000 = 1700、2 月 800
      expect(m['c1']!.last.spend, 1700);
      expect(m['c1']!.firstWhere((b) => b.start == DateTime(2026, 2, 1)).spend, 800);
      // c2：3 月 300、2 月 100
      expect(m['c2']!.last.spend, 300);
      expect(m['c2']!.firstWhere((b) => b.start == DateTime(2026, 2, 1)).spend, 100);
      // 兩者相加＝總覽的花費
      final all = bucketize(in2, Granularity.month, anchor);
      expect(m['c1']!.last.spend + m['c2']!.last.spend, all.last.spend);
    });

    test('預算只算自己分類；沒預算的分類算 0', () {
      final m = bucketizeByCategory(in2, Granularity.month, anchor);
      expect(m['c1']!.last.budget, 3100, reason: 'c1 有 3100');
      expect(m['c2']!.last.budget, 0, reason: 'c2 沒設預算');
      expect(m['c2']!.last.over, 300, reason: '沒預算時全額算超支');
    });

    test('balance 一律 0：分類沒有餘額概念', () {
      for (final g in Granularity.values) {
        final m = bucketizeByCategory(in2, g, anchor);
        for (final list in m.values) {
          expect(list.every((b) => b.balance == 0), isTrue, reason: '$g');
        }
      }
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

    test('日顆粒度：預算按當月天數攤到單一分類', () {
      final m = bucketizeByCategory(in2, Granularity.day, anchor);
      expect(m['c1']![0].budget, 100, reason: '3100 / 31');
      expect(m['c1']![4].spend, 700);
      expect(m['c2']![4].spend, 300);
    });
  });

  test('個人視角：桶內金額用我的份額', () {
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
        splitMethod: SplitMethod.common,
      ),
    ];
    final in3 = TrendInput(
      items: viewEntries(shared, ViewMode.personal, 'm', const {'m': 50, 'w': 50}),
      categories: const [c1],
      budgets: budgets,
      rolloverBasis: shared,
      opening: 1000,
    );
    final m = bucketize(in3, Granularity.month, anchor);
    expect(m.last.spend, 500);
    expect(m.last.balance, 500);
  });
}
