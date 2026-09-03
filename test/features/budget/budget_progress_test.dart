import 'package:accounting/domain/models.dart';
import 'package:accounting/features/budget/budget_progress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cat = Category(id: 'c', ledgerId: 'l', kind: EntryKind.expense, name: '食品', icon: 'x', sort: 0, rollover: true);
  const noRoll = Category(id: 'c2', ledgerId: 'l', kind: EntryKind.expense, name: '餐飲', icon: 'x', sort: 1);
  final jan = DateTime(2026, 1, 1);
  final feb = DateTime(2026, 2, 1);

  Entry exp(String id, String categoryId, int amt, DateTime on, {EntryScope scope = EntryScope.shared}) => Entry(
        id: id,
        ledgerId: 'l',
        kind: EntryKind.expense,
        scope: scope,
        amount: amt,
        categoryId: categoryId,
        occurredOn: on,
        createdBy: 'm',
      );

  group('categoryProgress', () {
    test('已花（僅 shared）、剩餘', () {
      final budgets = [Budget(id: 'b', ledgerId: 'l', categoryId: 'c', month: jan, limit: 5000)];
      final entries = [
        exp('e1', 'c', 2000, jan),
        exp('e2', 'c', 500, jan, scope: EntryScope.private), // 私人不算已花
      ];
      final p = categoryProgress(budgets: budgets, entries: entries, category: cat, month: jan);
      expect(p.baseLimit, 5000);
      expect(p.effectiveLimit, 5000);
      expect(p.spent, 2000);
      expect(p.remaining, 3000); // 5000-2000
      expect(p.overAmount, 0);
      expect(p.isOver, isFalse);
    });

    test('超支：已花段變 error、overAmount 為正、remaining 為 0', () {
      final budgets = [Budget(id: 'b', ledgerId: 'l', categoryId: 'c', month: jan, limit: 1000)];
      final entries = [exp('e1', 'c', 1500, jan)];
      final p = categoryProgress(budgets: budgets, entries: entries, category: cat, month: jan);
      expect(p.effectiveLimit, 1000);
      expect(p.spent, 1500);
      expect(p.overAmount, 500);
      expect(p.remaining, 0);
      expect(p.isOver, isTrue);
    });

    test('rollover 帶入有效上限：食品上月 5,500 花 6,200 → 本月有效 4,800', () {
      final budgets = [Budget(id: 'b', ledgerId: 'l', categoryId: 'c', month: jan, limit: 5500)];
      final entries = [exp('e1', 'c', 6200, jan)];
      final p = categoryProgress(budgets: budgets, entries: entries, category: cat, month: feb);
      expect(p.baseLimit, 5500);
      expect(p.effectiveLimit, 4800);
    });

    test('無預算：baseLimit/effectiveLimit 為 null，remaining/overAmount 為 0', () {
      final p = categoryProgress(budgets: const [], entries: const [], category: noRoll, month: jan);
      expect(p.baseLimit, isNull);
      expect(p.effectiveLimit, isNull);
      expect(p.hasBudget, isFalse);
      expect(p.remaining, 0);
      expect(p.overAmount, 0);
    });
  });

  group('summarizeBudget', () {
    test('跨分類加總', () {
      final rows = [
        const CategoryProgress(categoryId: 'a', baseLimit: 1000, effectiveLimit: 1000, spent: 400, overAmount: 0, remaining: 600),
        const CategoryProgress(categoryId: 'b', baseLimit: 500, effectiveLimit: 500, spent: 700, overAmount: 200, remaining: 0),
        const CategoryProgress(categoryId: 'c', baseLimit: null, effectiveLimit: null, spent: 50, overAmount: 0, remaining: 0),
      ];
      final overview = summarizeBudget(rows);
      expect(overview.totalSpent, 1150);
      expect(overview.totalLimit, 1500);
      expect(overview.totalRemaining, 600); // 各分類 remaining 加總＝600+0+0
      expect(overview.totalOver, 200);
    });
  });
}
