/// 設定本月預算 sheet（v1.4／ADR-0008）：一次寫一列 [BudgetAllocation]；
/// **每分類每月只能設定一次，設定後不可改、不可刪、不可逆轉**（DB 連 UPDATE／DELETE
/// 授權都收回了）。三種畫面（「已設定」判定看 `allocationsProvider` 的本地快取，不是
/// 每次開 sheet 都重打一次 server；快取落後於 server 的競態——例如另一台裝置剛設定過、
/// 這裡還沒 refresh／realtime 追上——放行編輯表單，送出時仍會撞真正的 unique 23505，
/// 由 repository 那層擋下並轉成「本月已設定」，見 `budget_page_test.dart` 的
/// unique 23505 測試）：
/// - 該分類本月已設定 → 唯讀顯示金額／備註／設定者／日期，沒有輸入欄，也沒有
///   修改或刪除入口。
/// - 該分類本月尚未設定、看的是過去月份 → 顯示「已過期，不可設定」，沒有輸入欄
///   （預算不跨月，過去月份補設也沒意義）。
/// - 該分類本月尚未設定、看的是當月或未來月 → 金額欄＋備註欄＋「設定」鈕。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/format.dart';
import '../../data/month_summary_provider.dart';
import '../../domain/balance_math.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';

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

  /// 設定日：看的是本月就記今天，看的是別的月就記該月 1 號（預算只看當月，日期不影響金額）。
  DateTime _occurredOn() {
    final now = DateTime.now();
    if (sameMonth(now, widget.month)) return DateTime(now.year, now.month, now.day);
    return DateTime(widget.month.year, widget.month.month, 1);
  }

  Future<void> _submit() async {
    final raw = int.tryParse(_amountController.text.trim());
    if (raw == null || raw <= 0) {
      setState(() => _error = '請輸入金額');
      return;
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
            amount: raw,
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

  String _memberName(List<Member> members, String id) {
    for (final m in members) {
      if (m.id == id) return m.displayName;
    }
    return '成員';
  }

  @override
  Widget build(BuildContext context) {
    final allocations = ref.watch(allocationsProvider);
    final members = ref.watch(membersProvider);
    // 本月已花吃 DB month_summary（首載前畫 0；任何寫入／輪詢後自動跟上 server）。
    final spent = ref.watch(monthSummaryProvider(_until)).value?.envelopeOf(widget.category.id).spent ?? 0;

    BudgetAllocation? existing;
    for (final a in allocations) {
      if (a.categoryId == widget.category.id && sameMonth(a.occurredOn, widget.month)) {
        existing = a;
        break;
      }
    }
    // canSubmit 只在編輯分支（existing == null && !_isPastMonth）用得到——過去月份
    // 未設定走的是上面那個 else if 分支，根本沒有這顆按鈕；這裡不必再判一次 _isPastMonth。
    final canSubmit = !_saving;

    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.category.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            // 「本月」寫死會在切到過去／未來月時文不對題（跟月份標題對不起來）；
            // 一律吃 widget.month 換算的月份字串，跟 AppBar 的 MonthTitle 是同一份資料。
            Text('${fmtMonth(widget.month)}已花 ${fmtAmount(spent)}', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 12),
            if (existing != null) ...[
              _detailRow(context, '金額', fmtAmount(existing.amount)),
              _detailRow(context, '備註', existing.note.isEmpty ? '（無）' : existing.note),
              _detailRow(context, '設定者', _memberName(members, existing.createdBy)),
              _detailRow(context, '日期', fmtDate(existing.occurredOn)),
            ] else if (_isPastMonth)
              Text('已過期，不可設定', style: TextStyle(color: Theme.of(context).colorScheme.error))
            else ...[
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
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('allocation-add-btn'),
                  onPressed: canSubmit ? _submit : null,
                  child: Text(_saving ? '處理中…' : '設定'),
                ),
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 64, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
            Expanded(child: Text(value, style: Theme.of(context).textTheme.bodyMedium)),
          ],
        ),
      );
}
