/// 個人補入區塊（v1.5／ADR-0009）：預算頁的「個人補入」卡片。
///
/// 每位成員一列（名稱、本月補入合計、先付、剩餘），數字來源與 [SummaryCard]／
/// [CategoryRow] 同一份 `monthSummaryProvider(until)`（DB 算好的 `MemberMonthLine`），
/// 首載前用 [balance_math] 現算 fallback（見 `build` 內的 `lineFor`／`_fallbackLine`），
/// 兩者在 `topup_section_test.dart` 有一條測試斷言一致。
///
/// 只有自己（[currentMemberIdProvider]）那列有「補入」鈕；已清月或還沒到的月份鈕停用
/// 並附一行原因。點列展開／收合本月補入明細，自己的筆在未清月可按刪除鈕
/// （二次確認）；已清月明細不給刪除入口。自己本月尚無補入、上月有 → 一行
/// 「複製上月」提示。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/format.dart';
import '../../data/month_summary_provider.dart';
import '../../domain/balance_math.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import '../../domain/month_summary.dart';
import 'budget_widgets.dart' show tabularStyle;
import 'topup_sheet.dart';

class TopupSection extends ConsumerStatefulWidget {
  const TopupSection({super.key, required this.month});

  /// 正在看的月份（月 1 號）。
  final DateTime month;

  @override
  ConsumerState<TopupSection> createState() => _TopupSectionState();
}

class _TopupSectionState extends ConsumerState<TopupSection> {
  final Set<String> _expanded = {};

  /// 複製上月進行中：避免連按兩次寫成兩倍（同 `budget_page._copying` 的理由）。
  bool _copying = false;

  DateTime get _until => DateTime(widget.month.year, widget.month.month + 1, 0);

  void _toggle(String memberId) => setState(() {
        if (!_expanded.remove(memberId)) _expanded.add(memberId);
      });

  void _openTopupSheet() {
    final month = widget.month;
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => TopupSheet(month: month),
    );
  }

  Future<void> _copyLastMonth(int amount) async {
    if (_copying) return;
    setState(() => _copying = true);
    final now = DateTime.now();
    final occurredOn =
        sameMonth(now, widget.month) ? DateTime(now.year, now.month, now.day) : DateTime(widget.month.year, widget.month.month, 1);
    final memberId = ref.read(currentMemberIdProvider);
    try {
      await ref.read(topupsProvider.notifier).add(PersonalTopup(
            id: '',
            ledgerId: ref.read(ledgerProvider).id,
            memberId: memberId,
            amount: amount,
            occurredOn: occurredOn,
            note: '複製上月',
            createdBy: memberId,
          ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is LedgerException ? e.message : '複製失敗，請稍後再試')),
      );
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  /// 進行中的刪除（補入 id 集合）：刪除鈕在這段期間停用，防連按送出兩次刪除，
  /// 失敗時也讓「鈕解除停用可重試」這件事有東西可驗（不是恆真式）。
  final Set<String> _deletingIds = {};

  Future<void> _deleteTopup(PersonalTopup t) async {
    if (_deletingIds.contains(t.id)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除補入'),
        content: Text('確定刪除這筆 ${fmtMoney(t.amount)} 的補入？'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('刪除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _deletingIds.add(t.id));
    try {
      await ref.read(topupsProvider.notifier).remove(t.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is LedgerException ? e.message : '刪除失敗，請稍後再試')),
      );
    } finally {
      if (mounted) setState(() => _deletingIds.remove(t.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final members = ref.watch(membersProvider);
    final currentId = ref.watch(currentMemberIdProvider);
    final topups = ref.watch(topupsProvider);
    final closes = ref.watch(monthClosesProvider);
    final summary = ref.watch(monthSummaryProvider(_until)).value;

    final closed = isMonthClosed(closes, widget.month);
    final isFuture = widget.month.isAfter(monthOf(DateTime.now()));
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // server（summary）還沒回來時，整份改用本地 balance_math 現算——不要逐欄位分開
    // `??`：那樣看不出「這一整份數字是不是同一個來源」，一個分支漏改就變成同一列
    // 一半 server 值一半本地值的怪東西。
    MemberMonthLine lineFor(Member m) {
      if (summary == null) return _fallbackLine(m, topups);
      return summary.memberLineOf(m.id);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('個人補入', style: textTheme.titleSmall),
            ),
            for (final m in members)
              _memberBlock(
                context,
                member: m,
                line: lineFor(m),
                isSelf: m.id == currentId,
                closed: closed,
                isFuture: isFuture,
                topups: topups,
                scheme: scheme,
                textTheme: textTheme,
              ),
          ],
        ),
      ),
    );
  }

  /// server（[monthSummaryProvider]）還沒回來前的本地 fallback：同一組
  /// `balance_math` 純函式（`topupIn`／`paidIn`／`topupRemaining`），與 DB 算式同源。
  /// `watch`（不是 `read`）：帳目變動時這條 fallback 也要跟著重算，不能停在首次 build 的值。
  MemberMonthLine _fallbackLine(Member m, List<PersonalTopup> topups) {
    final entries = ref.watch(entriesProvider);
    return MemberMonthLine(
      memberId: m.id,
      displayName: m.displayName,
      topup: topupIn(topups: topups, memberId: m.id, month: widget.month),
      paid: paidIn(entries: entries, memberId: m.id, month: widget.month),
      remaining: topupRemaining(topups: topups, entries: entries, memberId: m.id, month: widget.month),
    );
  }

  String? _disabledReason(bool closed, bool isFuture) {
    if (closed) return '該月已清帳';
    if (isFuture) return '尚未到該月';
    return null;
  }

  Widget _memberBlock(
    BuildContext context, {
    required Member member,
    required MemberMonthLine line,
    required bool isSelf,
    required bool closed,
    required bool isFuture,
    required List<PersonalTopup> topups,
    required ColorScheme scheme,
    required TextTheme textTheme,
  }) {
    final expanded = _expanded.contains(member.id);
    final secondary = textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    final remainingLabelStyle =
        textTheme.labelSmall?.copyWith(color: line.remaining < 0 ? scheme.error : scheme.onSurfaceVariant);
    final remainingValueStyle =
        tabularStyle(textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600, color: line.remaining < 0 ? scheme.error : null));
    final reason = isSelf ? _disabledReason(closed, isFuture) : null;

    final memberTopups = topups
        .where((t) => t.memberId == member.id && sameMonth(t.occurredOn, widget.month))
        .toList()
      ..sort((a, b) => a.occurredOn.compareTo(b.occurredOn));

    final prevMonthTopup = topupIn(topups: topups, memberId: member.id, month: prevMonth(widget.month));
    final showCopyPrompt = isSelf && !closed && !isFuture && memberTopups.isEmpty && prevMonthTopup > 0;
    final copyAmount = showCopyPrompt ? prevMonthTopup : 0;

    return Material(
      key: ValueKey('topup-row-${member.id}'),
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _toggle(member.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(member.displayName, style: textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  if (isSelf)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FilledButton.tonal(
                          key: const Key('topup-add-btn'),
                          onPressed: reason == null ? _openTopupSheet : null,
                          child: const Text('補入'),
                        ),
                        if (reason != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(reason, style: secondary),
                          ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('補入', style: secondary),
                  const SizedBox(width: 4),
                  Text(fmtAmount(line.topup), style: tabularStyle(secondary)),
                  const SizedBox(width: 12),
                  Text('先付', style: secondary),
                  const SizedBox(width: 4),
                  Text(fmtAmount(line.paid), style: tabularStyle(secondary)),
                  const SizedBox(width: 12),
                  Text('剩餘', style: remainingLabelStyle),
                  const SizedBox(width: 4),
                  Text(fmtAmount(line.remaining), style: remainingValueStyle),
                ],
              ),
              if (showCopyPrompt)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Expanded(child: Text('複製上月 ${fmtAmount(copyAmount)} 元', style: textTheme.bodySmall)),
                      const SizedBox(width: 8),
                      FilledButton.tonal(
                        key: ValueKey('topup-copy-last-month-btn-${member.id}'),
                        onPressed: _copying ? null : () => _copyLastMonth(copyAmount),
                        child: const Text('複製上月'),
                      ),
                    ],
                  ),
                ),
              if (expanded) ...[
                const SizedBox(height: 4),
                if (memberTopups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text('本月尚無補入', style: secondary),
                  )
                else
                  for (final t in memberTopups)
                    Padding(
                      key: ValueKey('topup-item-${t.id}'),
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Text(fmtDate(t.occurredOn), style: secondary),
                          const SizedBox(width: 8),
                          Text(fmtAmount(t.amount), style: tabularStyle(textTheme.bodySmall)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(t.note.isEmpty ? '（無備註）' : t.note,
                                style: secondary, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                          // 未來月理論上不會有補入（鈕與 sheet 都擋在更前面），這裡加
                          // `!isFuture` 只是防禦性守衛，跟 `!closed` 同一組道理：
                          // 刪除入口本身也不該在「不該寫」的月份出現。
                          if (isSelf && !closed && !isFuture)
                            IconButton(
                              key: ValueKey('topup-delete-${t.id}'),
                              // 點擊目標 ≥44px（UI 互動原則）：不用 VisualDensity.compact
                              // 縮小熱區，圖示本身仍維持小尺寸。
                              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: _deletingIds.contains(t.id) ? null : () => _deleteTopup(t),
                            ),
                        ],
                      ),
                    ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
