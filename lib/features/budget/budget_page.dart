import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/month_picker.dart';
import '../../app/tutorial.dart';
import '../../domain/balance_math.dart';
import '../../data/month_summary_provider.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import 'allocation_sheet.dart';
import 'budget_widgets.dart';

/// 預算 Tab（v1.3／ADR-0007）：頂部可用餘額＋信封總額／本月超支，每分類一列
/// 撥款／已花／剩餘／超支，點列開 sheet 撥款或退回；當月無撥款時提示可複製上月。
class BudgetPage extends ConsumerStatefulWidget {
  const BudgetPage({super.key});

  @override
  ConsumerState<BudgetPage> createState() => _BudgetPageState();
}

class _BudgetPageState extends ConsumerState<BudgetPage> {
  DateTime _month = monthOf(DateTime.now());

  /// 「複製上月」進行中：避免連按兩次寫成兩倍。
  bool _copying = false;

  /// 複製上月的部分失敗訊息（頁內顯示，不用會自己消失的 SnackBar）。
  String? _copyError;

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider);
    final allocations = ref.watch(allocationsProvider);

    final expenseCats = categories.where((c) => c.kind == EntryKind.expense).toList()..sort((a, b) => a.sort.compareTo(b.sort));

    // 信封只看當月，一律算到該月最後一天（本月尚未發生的日子沒有帳，算到月底與算到今天同值）。
    final until = DateTime(_month.year, _month.month + 1, 0);

    // 衍生數字一律吃 DB month_summary（Mike 裁示 2026-09-03）；重刷期間沿用上一份
    // server 值（AsyncValue 預設 skipLoadingOnRefresh），首載前先畫 0。
    final summary = ref.watch(monthSummaryProvider(until)).value;
    final available = summary?.sharedAvailable ?? 0;
    final envelopes = summary?.envelopeTotal ?? 0;
    final overAll = summary?.overspendTotal ?? 0;

    final rows = [
      for (final c in expenseCats)
        () {
          final env = summary?.envelopeOf(c.id);
          return CategoryRowData(
            category: c,
            allocated: env?.allocated ?? 0,
            spent: env?.spent ?? 0,
            remaining: env?.remaining ?? 0,
            over: env?.over ?? 0,
          );
        }(),
    ];

    // 「設定本月預算」提示：只在看的是當月或未來月、且該月完全沒有任何撥款紀錄時出現。
    final isCurrentOrFuture = !_month.isBefore(monthOf(DateTime.now()));
    final hasAllocationsThisMonth = allocations.any((a) => sameMonth(a.occurredOn, _month));
    final showPrompt = isCurrentOrFuture && !hasAllocationsThisMonth;

    // 複製上月候選：上月每個「撥款合計 > 0」的分類；退回後淨額歸零的分類不建（DB check 也不許 amount==0）。
    var copyPairs = const <(Category, int)>[];
    if (showPrompt) {
      final prevUntil = DateTime(_month.year, _month.month, 0); // 上月最後一天
      copyPairs = [
        for (final c in expenseCats)
          if (allocatedIn(allocations: allocations, categoryId: c.id, until: prevUntil) > 0)
            (c, allocatedIn(allocations: allocations, categoryId: c.id, until: prevUntil)),
      ];
    }

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
              KeyedSubtree(
                key: tutorialKey('budget-summary'),
                child: SummaryCard(available: available, envelopes: envelopes, overspend: overAll),
              ),
              if (showPrompt) ...[
                const SizedBox(height: 8),
                SetBudgetPrompt(
                  canCopy: copyPairs.isNotEmpty && !_copying,
                  onCopy: () => _copyLastMonth(copyPairs),
                ),
              ],
              if (_copyError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _copyError!,
                    key: const Key('copy-last-month-error'),
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              const SizedBox(height: 16),
              for (final r in rows) ...[
                CategoryRow(row: r, onTap: () => _openSheet(r.category)),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _openSheet(Category category) {
    final month = _month;
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => AllocationSheet(category: category, month: month),
    );
  }

  /// 對上月每個有撥款的分類，各建一筆本月 1 號、金額＝上月該分類撥款合計的撥款（備註「複製上月」）。
  ///
  /// 沒有批次寫入的入口（`budget_allocation` 一列＝一次撥款），所以逐筆寫；
  /// 中途失敗就停在那裡並顯示錯誤——已經寫進去的幾筆是有效撥款，不回頭刪。
  Future<void> _copyLastMonth(List<(Category, int)> pairs) async {
    if (_copying) return;
    setState(() {
      _copying = true;
      _copyError = null;
    });
    final notifier = ref.read(allocationsProvider.notifier);
    final createdBy = ref.read(currentMemberIdProvider);
    final ledgerId = ref.read(ledgerProvider).id;
    final month = _month;
    var done = 0;
    try {
      for (final (c, amount) in pairs) {
        await notifier.add(BudgetAllocation(
          // id 留空＝新筆，由 repository（Supabase 由 DB）產生。
          id: '',
          ledgerId: ledgerId,
          categoryId: c.id,
          amount: amount,
          occurredOn: DateTime(month.year, month.month, 1),
          note: '複製上月',
          createdBy: createdBy,
        ));
        done++;
      }
    } catch (e) {
      // 一列＝一次撥款，沒有批次入口，中途失敗就是「已建 N 筆、剩下沒建」。
      // 已建的那幾筆是有效撥款，不回頭刪；但一定要把數字講清楚，
      // 否則使用者只看到信封多了一半，不知道還缺什麼、也不知道能不能再按一次。
      if (mounted) {
        setState(() => _copyError =
            '已建 $done／${pairs.length} 筆，失敗：${e is LedgerException ? e.message : '請稍後再試'}');
      }
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }
}
