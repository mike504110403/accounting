/// 預算頁進度計算的純函式（wave1-budget-settings 專用）。BudgetPage 消費本檔，不放 UI。
library;

import '../../domain/budget_math.dart';
import '../../domain/models.dart';

/// 單一分類在指定月份的預算進度。
class CategoryProgress {
  const CategoryProgress({
    required this.categoryId,
    required this.baseLimit,
    required this.effectiveLimit,
    required this.spent,
    required this.overAmount,
    required this.remaining,
  });

  final String categoryId;

  /// 基礎上限；無預算為 null。
  final int? baseLimit;

  /// rollover 後的有效上限；無預算為 null。
  final int? effectiveLimit;

  /// 本月已花（僅 shared 支出）。
  final int spent;

  /// 超支金額；未超支或無預算為 0。
  final int overAmount;

  /// 有效上限扣掉已花後的剩餘；無預算或已超支為 0。不扣清單預留。
  final int remaining;

  bool get hasBudget => effectiveLimit != null;
  bool get isOver => overAmount > 0;
}

/// 算出 [category] 在 [month] 的預算進度。[entries] 傳全部 entry（含私人／收入），函式內部先過濾出 shared 支出。
/// v1.2 起清單只是購物車，未結帳不影響預算（Mike 2026-09-02 裁示），所以不再吃 listItems／算 reserved。
CategoryProgress categoryProgress({
  required List<Budget> budgets,
  required List<Entry> entries,
  required Category category,
  required DateTime month,
}) {
  final sharedExpenses = entries.where((e) => e.isExpense && e.scope == EntryScope.shared).toList();
  final base = baseLimit(budgets, category.id, month);
  final eff = effectiveLimit(budgets: budgets, entries: sharedExpenses, category: category, month: month);
  final spent = spentIn(sharedExpenses, category.id, month);
  final overAmount = (eff != null && spent > eff) ? spent - eff : 0;
  final remaining = eff == null ? 0 : _nonNegative(eff - spent);
  return CategoryProgress(
    categoryId: category.id,
    baseLimit: base,
    effectiveLimit: eff,
    spent: spent,
    overAmount: overAmount,
    remaining: remaining,
  );
}

int _nonNegative(int v) => v < 0 ? 0 : v;

/// 跨分類加總，供總覽卡使用。
class BudgetOverview {
  const BudgetOverview({required this.totalSpent, required this.totalLimit, required this.totalRemaining, required this.totalOver});
  final int totalSpent;
  final int totalLimit;
  final int totalRemaining;
  final int totalOver;
}

BudgetOverview summarizeBudget(List<CategoryProgress> rows) {
  var spent = 0;
  var limit = 0;
  var over = 0;
  var remaining = 0;
  for (final r in rows) {
    spent += r.spent;
    limit += r.effectiveLimit ?? 0;
    over += r.overAmount;
    // 用各分類已 clamp 過的 remaining（不會是負數）加總，跟卡片上顯示的數字一致，
    // 不要用 limit - spent 現算（超支分類會把整體「剩餘」往下拖成負數）。
    remaining += r.remaining;
  }
  return BudgetOverview(totalSpent: spent, totalLimit: limit, totalRemaining: remaining, totalOver: over);
}
