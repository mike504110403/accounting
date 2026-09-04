/// 清帳子頁（設定頁「清帳 ›」→ `/settings/closes`，spec v1.4「清帳」節／ADR-0008）。
///
/// 頁面做三件事：依前端推算的可清條件決定「清帳」按鈕的月份與 enabled（不可清時把原因
/// 寫成一行，字串與 `errors.dart` 全句相同）、按下去跑 `month_close_preview`、
/// 把 `month_closes` 依月份倒序列出來。
///
/// **RPC 仍是最終判定**：前端看不到別人的私人帳目，推算有機會與 DB 分岔
/// （例如按鈕是開的，RPC 卻回「請先清 2026／07」），那時一律顯示 RPC 回來的中文訊息。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/format.dart';
import '../../domain/balance_math.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import 'close_preview_sheet.dart';

/// 下一個可清月（顯示用）。規則同 spec 可清條件 (2)：
/// 清過 → 最後清帳月 ＋ 1 月；沒清過 → 最早的成員加入月或帳目月（兩者取早）。
///
/// 回 null ＝ 這本帳本連一位成員、一筆帳目都沒有。呼叫端還要自己夾「早於當月」，
/// 那是可清條件 (1)。
DateTime? nextClosableMonth({
  required Iterable<MonthClose> closes,
  required Iterable<Member> members,
  required Iterable<Entry> entries,
}) {
  DateTime? last;
  for (final c in closes) {
    final m = monthOf(c.month);
    if (last == null || m.isAfter(last)) last = m;
  }
  if (last != null) return nextMonth(last);

  DateTime? earliest;
  for (final m in members) {
    final j = monthOf(m.joinedAt);
    if (earliest == null || j.isBefore(earliest)) earliest = j;
  }
  for (final e in entries) {
    final m = monthOf(e.occurredOn);
    if (earliest == null || m.isBefore(earliest)) earliest = m;
  }
  return earliest;
}

/// 那個月還有沒有「已經拆帳、但還沒簽完」的帳目——可清條件 (3)。
///
/// 判準逐字比照 `month_close_guard` 與 `initiate_settlement`，**含「有分攤列」**：
/// 沒有分攤列的拆帳筆結算根本撿不到，擋了那個月永遠清不掉（那種筆改由預覽的 warnings 提醒）。
bool hasUnsettledSplits(Iterable<Entry> entries, DateTime month) => entries.any((e) =>
    e.scope == EntryScope.shared &&
    e.isExpense &&
    e.payerId != null &&
    e.splitMethod != SplitMethod.common &&
    e.settledState != SettledState.settled &&
    e.splits.isNotEmpty &&
    sameMonth(e.occurredOn, month));

/// 前端推算的「不能清」原因（可清時 null），字串與 `errors.dart` 的 RPC 訊息全句相同。
///
/// **這只是把按鈕先關起來、把原因講出來；真正的判定永遠在 RPC**——前端看不到別人的
/// 私人帳目，兩邊有機會分岔（例如 RPC 說「請先清 2026／07」），那時以按下去之後
/// 回來的中文訊息為準。
String? closeBlockReason({
  required DateTime? next,
  required Iterable<Entry> entries,
  DateTime? today,
}) {
  final current = monthOf(today ?? DateTime.now());
  // 條件 (4)：連一位成員、一筆帳目都沒有 → 根本推不出月份。
  if (next == null) return '沒有可清的月份';
  // 條件 (1)：那個月要先結束（下一個可清月就是本月時，得等這個月過完）。
  if (!next.isBefore(current)) return '本月尚未結束';
  // 條件 (3)：該月的拆帳要全部簽完。
  if (hasUnsettledSplits(entries, next)) return '有拆帳尚未簽完';
  return null;
}

/// 最後清帳月（沒有就 null）：設定頁那列「上次清帳 YYYY／MM」用。
DateTime? lastClosedMonth(Iterable<MonthClose> closes) {
  DateTime? last;
  for (final c in closes) {
    final m = monthOf(c.month);
    if (last == null || m.isAfter(last)) last = m;
  }
  return last;
}

class ClosesPage extends ConsumerStatefulWidget {
  const ClosesPage({super.key});

  @override
  ConsumerState<ClosesPage> createState() => _ClosesPageState();
}

class _ClosesPageState extends ConsumerState<ClosesPage> {
  bool _loading = false;
  String? _error;

  /// 按鈕 → 預覽。RPC raise 就把中文訊息顯示在按鈕下方一行，不開 sheet。
  Future<void> _openPreview(String ledgerId, DateTime month) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final MonthCloseDetails details;
    try {
      details = await ref.read(ledgerRepositoryProvider).monthClosePreview(ledgerId, month);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is LedgerException ? e.message : '預覽失敗，請稍後再試';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _loading = false);
    final closed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ClosePreviewSheet(month: month, details: details),
    );
    if (closed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已清帳 ${fmtYearMonth(month)}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ledger = ref.watch(ledgerProvider);
    final members = ref.watch(membersProvider);
    final entries = ref.watch(entriesProvider);
    // watch 的是 provider 不是快照：清完自己 refresh、別的裝置清帳走 Realtime，兩條都會重建。
    final closes = ref.watch(monthClosesProvider);

    final next = nextClosableMonth(closes: closes, members: members, entries: entries);
    final blocked = closeBlockReason(next: next, entries: entries);
    // blocked == null 蘊含 next 非 null（`closeBlockReason` 的第一條就是它）。
    final closableMonth = blocked == null ? next : null;
    // 月份寫在按鈕上只在「那個月確實還等著被清」時才有意義：
    // 「沒有可清的月份」時寫上本月，會變成邀請使用者去清一個清不了的月。
    final buttonMonth = next != null && next.isBefore(monthOf(DateTime.now())) ? next : null;

    final sorted = [...closes]..sort((a, b) => b.month.compareTo(a.month));

    return Scaffold(
      appBar: AppBar(title: const Text('清帳')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FilledButton(
                          key: const Key('close-month-button'),
                          onPressed: closableMonth == null || _loading
                              ? null
                              : () => _openPreview(ledger.id, closableMonth),
                          child: Text(
                              buttonMonth == null ? '清帳' : '清帳 ${fmtYearMonth(buttonMonth)}'),
                        ),
                        if (blocked != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              blocked,
                              key: const Key('close-disabled-reason'),
                              style: t.textTheme.bodySmall
                                  ?.copyWith(fontSize: 12, color: t.colorScheme.onSurfaceVariant),
                            ),
                          ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              _error!,
                              key: const Key('close-error'),
                              style: t.textTheme.bodySmall
                                  ?.copyWith(fontSize: 12, color: t.colorScheme.error),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (sorted.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                    child: Text(
                      '尚未清帳',
                      textAlign: TextAlign.center,
                      style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                  )
                else
                  Card(
                    child: Column(
                      children: [
                        for (final c in sorted) _CloseTile(close: c, members: members),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 清帳列表的一列：一行摘要，點開才給完整明細（spec UI 互動原則：資訊密度）。
class _CloseTile extends StatelessWidget {
  const _CloseTile({required this.close, required this.members});

  final MonthClose close;
  final List<Member> members;

  /// 清帳者暱稱：先問現在的成員清單，查不到就退回快照裡當時的名字（成員退出也還看得到是誰清的）。
  String get _closerName {
    for (final m in members) {
      if (m.id == close.closedBy) return m.displayName;
    }
    for (final l in close.details.members) {
      if (l.memberId == close.closedBy) return l.displayName;
    }
    return '成員';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final d = close.closedAt;
    final endings = [
      for (final l in close.details.members) '${l.displayName} ${fmtSignedAmount(l.ending)}',
    ].join(' / ');
    return ExpansionTile(
      key: ValueKey('close-tile-${close.id}'),
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      title: Text('${fmtYearMonth(close.month)}・$_closerName・${fmtDateFull(d)}'),
      subtitle: Text(
        endings,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
      ),
      children: [CloseDetailsView(details: close.details)],
    );
  }
}
