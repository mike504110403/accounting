/// 撥款／退回 sheet（v1.3／ADR-0007）：一次寫一列 [BudgetAllocation]；下方看得到當月撥款流水並可刪除。
/// 過去月份不可撥款（信封不跨月，補撥過去月沒有意義）——按鈕 disabled，欄位仍可看。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/circle_slide_action.dart';
import '../../app/format.dart';
import '../../data/month_summary_provider.dart';
import '../../domain/balance_math.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import 'budget_widgets.dart';

class AllocationSheet extends ConsumerStatefulWidget {
  const AllocationSheet({super.key, required this.category, required this.month});
  final Category category;

  /// 正在看的月份（月 1 號），不一定是當月。
  final DateTime month;

  @override
  ConsumerState<AllocationSheet> createState() => _AllocationSheetState();
}

class _AllocationSheetState extends ConsumerState<AllocationSheet> {
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  bool get _isPastMonth => widget.month.isBefore(monthOf(DateTime.now()));

  DateTime get _until => DateTime(widget.month.year, widget.month.month + 1, 0);

  /// 撥款日：看的是本月就記今天，看的是別的月就記該月 1 號（信封只看當月，日期只影響「算到某日」）。
  DateTime _occurredOn() {
    final now = DateTime.now();
    if (sameMonth(now, widget.month)) return DateTime(now.year, now.month, now.day);
    return DateTime(widget.month.year, widget.month.month, 1);
  }

  Future<void> _submit({required bool isReturn}) async {
    final raw = int.tryParse(_amountController.text.trim());
    if (raw == null || raw <= 0) {
      setState(() => _error = '請輸入金額');
      return;
    }

    if (isReturn) {
      // 退回上限吃 DB month_summary 的剩餘（server 資料計算；Mike 裁示 2026-09-03）。
      final remainingNow =
          ref.read(monthSummaryProvider(_until)).value?.envelopeOf(widget.category.id).remaining ?? 0;
      if (raw > remainingNow) {
        setState(() => _error = '退回不得超過剩餘 ${fmtAmount(remainingNow)}');
        return;
      }
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(allocationsProvider.notifier).add(BudgetAllocation(
            // id 留空＝新筆，由 repository（Supabase 由 DB）產生。
            id: '',
            ledgerId: ref.read(ledgerProvider).id,
            categoryId: widget.category.id,
            amount: isReturn ? -raw : raw,
            occurredOn: _occurredOn(),
            note: _noteController.text.trim(),
            createdBy: ref.read(currentMemberIdProvider),
          ));
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is LedgerException ? e.message : '儲存失敗，請重試';
      });
    }
  }

  Future<void> _remove(String id) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(allocationsProvider.notifier).remove(id);
      if (mounted) setState(() => _saving = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is LedgerException ? e.message : '刪除失敗，請重試';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final allocations = ref.watch(allocationsProvider);
    // 本月三數字吃 DB month_summary（首載前畫 0；任何寫入／輪詢後自動跟上 server）。
    final env = ref.watch(monthSummaryProvider(_until)).value?.envelopeOf(widget.category.id);
    final allocated = env?.allocated ?? 0;
    final spent = env?.spent ?? 0;
    final remaining = env?.remaining ?? 0;

    final flow = allocations.where((a) => a.categoryId == widget.category.id && sameMonth(a.occurredOn, widget.month)).toList()
      ..sort((a, b) => a.occurredOn.compareTo(b.occurredOn));

    final canSubmit = !_isPastMonth && !_saving;

    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.category.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '本月：撥款 ${fmtAmount(allocated)}・已花 ${fmtAmount(spent)}・剩餘 ${fmtAmount(remaining)}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('allocation-amount-field'),
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(signed: false),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: '金額'),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('allocation-note-field'),
              controller: _noteController,
              decoration: const InputDecoration(labelText: '備註'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (_isPastMonth)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('過去月份不可撥款', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const Key('allocation-return-btn'),
                    onPressed: canSubmit ? () => _submit(isReturn: true) : null,
                    child: const Text('退回'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    key: const Key('allocation-add-btn'),
                    onPressed: canSubmit ? () => _submit(isReturn: false) : null,
                    child: Text(_saving ? '處理中…' : '撥入'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('本月撥款流水', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            if (flow.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('本月還沒有撥款紀錄', style: Theme.of(context).textTheme.bodySmall),
              )
            else
              for (final a in flow)
                // 左滑刪除（Mike 裁示 2026-09-04：不放 X 按鈕）。
                Slidable(
                  key: ValueKey('allocation-flow-${a.id}'),
                  endActionPane: ActionPane(
                    motion: const DrawerMotion(),
                    extentRatio: 0.22,
                    children: [
                      CircleSlideAction(
                        key: Key('allocation-delete-${a.id}'),
                        icon: Icons.delete_outline,
                        background: Theme.of(context).colorScheme.errorContainer,
                        foreground: Theme.of(context).colorScheme.onErrorContainer,
                        tooltip: '刪除',
                        onPressed: () {
                          if (!_saving) _remove(a.id);
                        },
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        Text(fmtDate(a.occurredOn), style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 3,
                          child: Text(fmtAmount(a.amount), maxLines: 1, overflow: TextOverflow.ellipsis, style: tabularStyle(null)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(flex: 2, child: Text(a.note, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
