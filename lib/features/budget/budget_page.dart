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

/// 預算 Tab（v1.4／ADR-0008）：頂部四數字（共同餘額／本月預算／本月共同支出／本月超支），
/// 每分類一列預算／已花／剩餘／超支，點列開 sheet 設定本月預算；本月完全沒有任何預算時
/// 提示可複製上月（只補上月有值且本月尚未設定的分類）。
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

    // 預算只看當月，一律算到該月最後一天（本月尚未發生的日子沒有帳，算到月底與算到今天同值）。
    final until = DateTime(_month.year, _month.month + 1, 0);

    // 衍生數字一律吃 DB month_summary（Mike 裁示 2026-09-03）；重刷期間沿用上一份
    // server 值（AsyncValue 預設 skipLoadingOnRefresh），首載前先畫 0。
    final summary = ref.watch(monthSummaryProvider(until)).value;
    final topBalance = summary?.sharedBalance ?? 0;
    final topBudget = summary?.budgetTotal ?? 0;
    final topSpent = summary?.spentTotal ?? 0;
    final topOver = summary?.overspendTotal ?? 0;

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

    // 「設定本月預算」提示：只在看的是當月或未來月、summary 已經首載完成、且該月完全
    // 沒有任何預算時出現（spec 口徑）。「已設定」判定一律看 monthSummary.envelopeOf(id)
    // .allocated（與頁面其他數字同源），不回頭重算 allocations 原始清單。
    // summary == null（首載還沒回來）時一律不顯示：不然會先閃一次「假的全空」提示，
    // 使用者這時按下複製，事後 summary 回來才發現其實已經設定過，白白撞 23505。
    bool isSetThisMonth(Category c) => (summary?.envelopeOf(c.id).allocated ?? 0) > 0;
    final isCurrentOrFuture = !_month.isBefore(monthOf(DateTime.now()));
    final hasAllocationsThisMonth = expenseCats.any(isSetThisMonth);
    final showPrompt = summary != null && isCurrentOrFuture && !hasAllocationsThisMonth;

    // 複製上月候選：上月有預算、**且本月尚未設定**的分類（每分類每月只能設定一次，
    // 已設定的再送一次會被 unique 擋成 23505）。showPrompt 已經保證本月全空，這裡的
    // 「本月未設定」再判一次是防禦性寫法（同 isSetThisMonth 同源）。
    var copyPairs = const <(Category, int)>[];
    if (showPrompt) {
      final prevMonthStart = prevMonth(_month);
      copyPairs = [
        for (final c in expenseCats)
          if (allocatedIn(allocations: allocations, categoryId: c.id, month: prevMonthStart) > 0 &&
              !isSetThisMonth(c))
            (c, allocatedIn(allocations: allocations, categoryId: c.id, month: prevMonthStart)),
      ];
    }

    return Scaffold(
      appBar: AppBar(
        title: MonthTitle(
          month: _month,
          onChanged: (m) => setState(() {
            _month = m;
            // 切月等於看另一個月的複製上月狀態；上一個月殘留的錯誤訊息在新月份下
            // 已經文不對題，一併清掉。
            _copyError = null;
          }),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              KeyedSubtree(
                key: tutorialKey('budget-summary'),
                child: SummaryCard(
                  sharedBalance: topBalance,
                  budgetTotal: topBudget,
                  spentTotal: topSpent,
                  overspendTotal: topOver,
                ),
              ),
              if (showPrompt) ...[
                const SizedBox(height: 8),
                SetBudgetPrompt(
                  canCopy: copyPairs.isNotEmpty,
                  busy: _copying,
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

  /// 對上月有預算、本月尚未設定的分類，各建一筆本月 1 號、金額＝上月該分類預算的預算
  /// （備註「複製上月」）。
  ///
  /// 沒有批次寫入的入口（`budget_allocation` 一列＝一個分類一個月），所以逐筆寫；
  /// 中途失敗就停在那裡並顯示錯誤——已經寫進去的幾筆是有效預算，設定後不可刪。
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
      // 一列＝一個分類一個月，沒有批次入口，中途失敗就是「已建 N 筆、剩下沒建」。
      // 已建的那幾筆是有效預算，設定後不可刪；但一定要把數字講清楚，
      // 否則使用者只看到預算多了一半，不知道還缺什麼、也不知道能不能再按一次。
      if (mounted) {
        setState(() => _copyError =
            '已建 $done／${pairs.length} 筆，失敗：${e is LedgerException ? e.message : '請稍後再試'}');
      }
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }
}
