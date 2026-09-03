import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/category_icon.dart';
import '../../app/format.dart';
import '../../app/month_picker.dart';
import '../../domain/budget_math.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import 'budget_progress.dart';

/// 預算 Tab：每分類上限、三段進度條、rollover、收入與損益（波 1 工人實作，替換本檔內容）。
class BudgetPage extends ConsumerStatefulWidget {
  const BudgetPage({super.key});

  @override
  ConsumerState<BudgetPage> createState() => _BudgetPageState();
}

class _BudgetPageState extends ConsumerState<BudgetPage> {
  DateTime _month = monthOf(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider);
    final entries = ref.watch(entriesProvider);
    final budgets = ref.watch(budgetsProvider);
    final ledger = ref.watch(ledgerProvider);

    final expenseCats = categories.where((c) => c.kind == EntryKind.expense).toList()..sort((a, b) => a.sort.compareTo(b.sort));
    final incomeCats = categories.where((c) => c.kind == EntryKind.income).toList()..sort((a, b) => a.sort.compareTo(b.sort));

    final rows = [
      for (final c in expenseCats) categoryProgress(budgets: budgets, entries: entries, category: c, month: _month),
    ];
    final overview = summarizeBudget(rows);

    final sharedEntries = entries.where((e) => e.scope == EntryScope.shared).toList();
    final incomeThisMonth = <String, int>{
      for (final c in incomeCats)
        c.id: sharedEntries
            .where((e) => e.kind == EntryKind.income && e.categoryId == c.id && sameMonth(e.occurredOn, _month))
            .fold<int>(0, (s, e) => s + e.amount),
    };
    final totalIncome = incomeThisMonth.values.fold<int>(0, (a, b) => a + b);
    final totalExpenseThisMonth = sharedEntries.where((e) => e.isExpense && sameMonth(e.occurredOn, _month)).fold<int>(0, (s, e) => s + e.amount);
    final profit = totalIncome - totalExpenseThisMonth;
    final monthEnd = DateTime(_month.year, _month.month + 1, 0);
    final balance = runningBalance(opening: ledger.openingBalanceShared, entries: sharedEntries, until: monthEnd);

    return Scaffold(
      appBar: AppBar(
        title: MonthTitle(month: _month, onChanged: (m) => setState(() => _month = m)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _OverviewCard(overview: overview),
              const SizedBox(height: 16),
              for (final c in expenseCats) ...[
                _CategoryCard(category: c, progress: rows.firstWhere((r) => r.categoryId == c.id), month: _month),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 4),
              _IncomeSection(incomeCats: incomeCats, incomeThisMonth: incomeThisMonth, totalIncome: totalIncome, profit: profit, balance: balance),
            ],
          ),
        ),
      ),
    );
  }
}

/// 金額數字用等寬數字（tabular figures），對齊卡片間的欄位；style 為 null 時仍套用（併入 Text 的 ambient 樣式）。
TextStyle _tabular([TextStyle? style]) => (style ?? const TextStyle()).merge(const TextStyle(fontFeatures: [FontFeature.tabularFigures()]));

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({required this.overview});
  final BudgetOverview overview;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('本月總覽', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _stat(context, '支出合計', fmtMoney(overview.totalSpent))),
                Expanded(child: _stat(context, '有效上限合計', fmtMoney(overview.totalLimit))),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _stat(context, '剩餘', fmtMoney(overview.totalRemaining))),
                Expanded(
                  child: _stat(context, '超支總額', fmtMoney(overview.totalOver), color: overview.totalOver > 0 ? scheme.error : null),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(BuildContext context, String label, String value, {Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(value, style: _tabular(Theme.of(context).textTheme.titleMedium?.copyWith(color: color))),
      ],
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({required this.category, required this.progress, required this.month});
  final Category category;
  final CategoryProgress progress;
  final DateTime month;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20), // 貼齊 CardThemeData 的圓角，ripple 不會露角
        onTap: () => showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (_) => _BudgetSheet(category: category, month: month, currentBase: progress.baseLimit),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.primaryContainer),
                    child: Icon(categoryIcon(category.icon), size: 20, color: scheme.onPrimaryContainer),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(category.name, style: Theme.of(context).textTheme.titleMedium)),
                  if (category.rollover)
                    Chip(
                      label: const Text('累計'),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                progress.hasBudget ? '基礎 ${fmtAmount(progress.baseLimit ?? 0)}／有效 ${fmtAmount(progress.effectiveLimit!)}' : '未設定',
                style: _tabular(Theme.of(context).textTheme.bodySmall),
              ),
              const SizedBox(height: 8),
              if (progress.hasBudget) _ProgressBar(progress: progress),
              if (progress.isOver) ...[
                const SizedBox(height: 4),
                Text('超支 ${fmtAmount(progress.overAmount)}', style: _tabular(TextStyle(color: scheme.error, fontWeight: FontWeight.w600))),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.progress});
  final CategoryProgress progress;

  int _flex(int v, int scale) => scale <= 0 ? 1 : (((v / scale) * 1000).round()).clamp(1, 100000);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final limit = progress.effectiveLimit!;
    // 清單預留段已移除（Mike 2026-09-02 裁示：清單只是購物車，未結帳不影響預算），只剩已花／剩餘兩段。
    final scale = [limit, progress.spent, 1].reduce((a, b) => a > b ? a : b);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: Row(
          children: [
            Expanded(flex: _flex(progress.spent, scale), child: Container(color: progress.isOver ? scheme.error : scheme.primary)),
            Expanded(flex: _flex(progress.remaining, scale), child: Container(color: scheme.surfaceContainerHighest)),
          ],
        ),
      ),
    );
  }
}

class _BudgetSheet extends ConsumerStatefulWidget {
  const _BudgetSheet({required this.category, required this.month, required this.currentBase});
  final Category category;
  final DateTime month;
  final int? currentBase;

  @override
  ConsumerState<_BudgetSheet> createState() => _BudgetSheetState();
}

class _BudgetSheetState extends ConsumerState<_BudgetSheet> {
  late final TextEditingController _controller = TextEditingController(text: widget.currentBase?.toString() ?? '');
  late bool _rollover = widget.category.rollover;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final text = _controller.text.trim();
    int? value;
    if (text.isNotEmpty) {
      value = int.tryParse(text);
      if (value == null || value < 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('請輸入有效金額')));
        return;
      }
    }
    // 金額欄留空＝不改上限，只套用 rollover 開關差異；只有「有填但非法」才擋在上面。
    setState(() => _saving = true);
    try {
      if (value != null) {
        final target = monthOf(widget.month);
        final budgets = ref.read(budgetsProvider);
        Budget? existing;
        for (final b in budgets) {
          if (b.categoryId == widget.category.id && b.month == target) existing = b;
        }
        final id = existing?.id ?? 'b-${widget.category.id}-${target.year}-${target.month}';
        ref.read(budgetsProvider.notifier).upsert(Budget(id: id, ledgerId: kLedgerId, categoryId: widget.category.id, month: target, limit: value));
      }
      if (_rollover != widget.category.rollover) {
        final c = widget.category;
        ref.read(categoriesStateProvider.notifier).update(Category(id: c.id, ledgerId: c.ledgerId, kind: c.kind, name: c.name, icon: c.icon, sort: c.sort, rollover: _rollover));
      }
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('儲存失敗，請重試')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.category.name, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: '本月上限'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('累計 rollover'),
            value: _rollover,
            onChanged: (v) => setState(() => _rollover = v),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? '儲存中…' : '儲存')),
          ),
        ],
      ),
    );
  }
}

class _IncomeSection extends StatelessWidget {
  const _IncomeSection({required this.incomeCats, required this.incomeThisMonth, required this.totalIncome, required this.profit, required this.balance});
  final List<Category> incomeCats;
  final Map<String, int> incomeThisMonth;
  final int totalIncome;
  final int profit;
  final int balance;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('收入與損益', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final c in incomeCats)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [Text(c.name), Text(fmtMoney(incomeThisMonth[c.id] ?? 0), style: _tabular(null))],
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [const Text('收入合計'), Text(fmtMoney(totalIncome), style: _tabular(null))],
              ),
            ),
            const Divider(height: 20),
            _line(context, '本月損益', fmtMoney(profit), color: profit < 0 ? scheme.error : null),
            _line(context, '累計餘額', fmtMoney(balance)),
          ],
        ),
      ),
    );
  }

  Widget _line(BuildContext context, String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [Text(label), Text(value, style: _tabular(TextStyle(fontWeight: FontWeight.w600, color: color)))],
      ),
    );
  }
}
