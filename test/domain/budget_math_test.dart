import 'package:accounting/domain/budget_math.dart';
import 'package:accounting/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cat = Category(id: 'c', ledgerId: 'l', kind: EntryKind.expense, name: '食品', icon: 'x', sort: 0, rollover: true);
  final jan = DateTime(2026, 1, 1);
  final feb = DateTime(2026, 2, 1);
  final mar = DateTime(2026, 3, 1);
  Entry exp(int amt, DateTime on) => Entry(id: 'e$amt${on.month}', ledgerId: 'l', kind: EntryKind.expense, scope: EntryScope.shared, amount: amt, categoryId: 'c', occurredOn: on, createdBy: 'm');

  test('rollover 正負都帶、遞推到目標月', () {
    final budgets = [Budget(id: 'b', ledgerId: 'l', categoryId: 'c', month: jan, limit: 5000)];
    final entries = [exp(4000, jan), exp(6000, feb)];
    // 1 月剩 1000 → 2 月有效 6000，花 6000 剩 0 → 3 月 5000
    expect(effectiveLimit(budgets: budgets, entries: entries, category: cat, month: feb), 6000);
    expect(effectiveLimit(budgets: budgets, entries: entries, category: cat, month: mar), 5000);
    // 2 月超支 → 3 月被扣
    final over = [exp(4000, jan), exp(7000, feb)];
    expect(effectiveLimit(budgets: budgets, entries: over, category: cat, month: mar), 4000);
  });

  test('rollover 關閉時只回基礎上限；基礎上限改動只影響該月起', () {
    const noRoll = Category(id: 'c', ledgerId: 'l', kind: EntryKind.expense, name: '食品', icon: 'x', sort: 0);
    final budgets = [
      Budget(id: 'b1', ledgerId: 'l', categoryId: 'c', month: jan, limit: 5000),
      Budget(id: 'b2', ledgerId: 'l', categoryId: 'c', month: mar, limit: 7000),
    ];
    expect(effectiveLimit(budgets: budgets, entries: const [], category: noRoll, month: feb), 5000);
    expect(effectiveLimit(budgets: budgets, entries: const [], category: noRoll, month: mar), 7000);
  });

  test('runningBalance 期初＋收入−支出', () {
    final inc = Entry(id: 'i', ledgerId: 'l', kind: EntryKind.income, scope: EntryScope.shared, amount: 1000, categoryId: 's', occurredOn: jan, createdBy: 'm');
    expect(runningBalance(opening: 100, entries: [inc, exp(300, feb)], until: mar), 800);
    expect(runningBalance(opening: 100, entries: [inc, exp(300, feb)], until: jan), 1100);
  });
}
