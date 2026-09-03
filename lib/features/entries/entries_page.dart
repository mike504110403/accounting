import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/category_icon.dart';
import '../../app/format.dart';
import '../../app/month_app_bar.dart';
import '../../domain/budget_math.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import 'entry_colors.dart';
import 'search_page.dart';
import 'settlement_math.dart';

/// 帳目頁：月份／視角切換、結算卡片、月摘要、依日分組列表。
class EntriesPage extends ConsumerStatefulWidget {
  const EntriesPage({super.key});

  @override
  ConsumerState<EntriesPage> createState() => _EntriesPageState();
}

class _EntriesPageState extends ConsumerState<EntriesPage> {
  DateTime _month = monthOf(DateTime.now());
  ViewMode _view = ViewMode.family;

  void _setMonth(DateTime m) => setState(() => _month = monthOf(m));

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 本視角看得到的 entry：家庭＝只看共同；個人＝自己的私人＋共同。
  bool _visible(Entry e, String me) =>
      e.scope == EntryScope.shared || (_view == ViewMode.personal && e.createdBy == me);

  /// 本視角下這筆算多少：家庭看全額，個人看自己的份額。
  int _shown(Entry e, String me, Map<String, int> ratio) =>
      _view == ViewMode.family ? e.amount : myPortion(e, me, ratio);

  /// 把 settlement 的既有欄位帶著新的簽核集合重建；簽完就落 settled。
  Settlement _withApproval(Settlement s, Set<String> approvedBy) {
    // 需簽者＝淨額非零成員−發起人（ADR-0002），與已簽集合無關，可直接比對。
    final done = s.requiredSigners.difference(approvedBy).isEmpty;
    return Settlement(
      id: s.id,
      ledgerId: s.ledgerId,
      status: done ? SettlementStatus.settled : s.status,
      initiatedBy: s.initiatedBy,
      createdAt: s.createdAt,
      settledAt: done ? DateTime.now() : s.settledAt,
      nets: s.nets,
      entryIds: s.entryIds,
      approvedBy: approvedBy,
    );
  }

  /// 補償：把 entries 寫回原狀（真正的原子性由波 2 的 Postgres RPC 保證，這裡是 mock 層補償）。
  void _restoreEntries(List<Entry> originals) {
    try {
      for (final e in originals) {
        ref.read(entriesProvider.notifier).update(e);
      }
    } catch (e, st) {
      debugPrint('結算補償寫回失敗: $e\n$st');
    }
  }

  /// 同意簽核。先寫 entries（可補償），settlement 寫入是提交點；
  /// 原子性由波 2 RPC 保證，此為 mock 層補償。
  void _approve(Settlement s) {
    final me = ref.read(currentMemberIdProvider);
    final next = _withApproval(s, {...s.approvedBy, me});
    final done = next.status == SettlementStatus.settled;

    final originals = <Entry>[];
    if (done) {
      for (final e in ref.read(entriesProvider)) {
        if (next.entryIds.contains(e.id)) originals.add(e);
      }
    }

    try {
      for (final e in originals) {
        ref.read(entriesProvider.notifier).update(e.copyWith(settledState: SettledState.settled));
      }
    } catch (e, st) {
      debugPrint('簽核寫入 entries 失敗: $e\n$st');
      _restoreEntries(originals);
      _toast('簽核失敗，請稍後再試');
      return;
    }

    try {
      ref.read(settlementsProvider.notifier).update(next);
    } catch (e, st) {
      debugPrint('簽核寫入 settlement 失敗: $e\n$st');
      _restoreEntries(originals);
      _toast('簽核失敗，請稍後再試');
      return;
    }
    _toast(done ? '已完成結算' : '已送出同意');
  }

  /// 發起結算。先把 entries 轉狀態（可補償），add settlement 是提交點；
  /// 原子性由波 2 RPC 保證，此為 mock 層補償。
  void _startSettlement(List<Entry> targets, List<Member> members, String ledgerId) {
    if (targets.isEmpty) return;
    final me = ref.read(currentMemberIdProvider);
    final nets = computeNets(targets, members);
    final entryIds = [for (final e in targets) e.id];
    final draft = Settlement(
      id: 'st-${DateTime.now().microsecondsSinceEpoch}',
      ledgerId: ledgerId,
      status: SettlementStatus.pending,
      initiatedBy: me,
      createdAt: DateTime.now(),
      nets: nets,
      entryIds: entryIds,
      approvedBy: const {},
    );
    // 沒有人需要簽（需簽者＝淨額非零成員−發起人）時直接成立，否則會卡成永遠 pending。
    final settleNow = draft.fullyApproved;
    final settlement = settleNow ? _withApproval(draft, const {}) : draft;
    final nextState = settleNow ? SettledState.settled : SettledState.settling;

    try {
      for (final e in targets) {
        ref.read(entriesProvider.notifier).update(e.copyWith(settledState: nextState));
      }
    } catch (e, st) {
      debugPrint('發起結算寫入 entries 失敗: $e\n$st');
      _restoreEntries(targets);
      _toast('發起結算失敗，請稍後再試');
      return;
    }

    try {
      ref.read(settlementsProvider.notifier).add(settlement);
    } catch (e, st) {
      debugPrint('發起結算寫入 settlement 失敗: $e\n$st');
      _restoreEntries(targets);
      _toast('發起結算失敗，請稍後再試');
      return;
    }
    _toast(settleNow ? '已完成結算' : '已發起結算，等待簽核');
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentMemberIdProvider);
    final ledger = ref.watch(ledgerProvider);
    final members = ref.watch(membersProvider);
    final categories = ref.watch(categoriesProvider);
    final all = ref.watch(entriesProvider);
    final settlements = ref.watch(settlementsProvider);

    final monthEntries = [
      for (final e in all)
        if (_visible(e, me) && sameMonth(e.occurredOn, _month)) e,
    ]..sort((a, b) => b.occurredOn.compareTo(a.occurredOn));

    var income = 0, expense = 0;
    for (final e in monthEntries) {
      final v = _shown(e, me, ledger.defaultRatio);
      if (e.isExpense) {
        expense += v;
      } else {
        income += v;
      }
    }

    final pending = [
      for (final s in settlements)
        if (s.status == SettlementStatus.pending) s,
    ];
    final settleable = [
      for (final e in all)
        if (isSettleable(e)) e,
    ];

    final groups = <DateTime, List<Entry>>{};
    for (final e in monthEntries) {
      final k = DateTime(e.occurredOn.year, e.occurredOn.month, e.occurredOn.day);
      (groups[k] ??= []).add(e);
    }
    final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    return Scaffold(
      appBar: MonthAppBar(
        month: _month,
        onMonthChanged: _setMonth,
        view: _view,
        onViewChanged: (v) => setState(() => _view = v),
        leading: IconButton(
          icon: const Icon(Icons.search),
          tooltip: '搜尋',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const EntrySearchPage()),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '設定',
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/entries/new'),
        icon: const Icon(Icons.add),
        label: const Text('新增'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 96),
                    children: [
                      if (pending.isNotEmpty)
                        _SettlementBar.pending(
                          settlement: pending.first,
                          members: members,
                          me: me,
                          onApprove: () => _approve(pending.first),
                        )
                      else if (settleable.isNotEmpty)
                        _SettlementBar.start(
                          nets: computeNets(settleable, members),
                          me: me,
                          count: settleable.length,
                          onStart: () => _startSettlement(settleable, members, ledger.id),
                        ),
                      _MonthSummary(income: income, expense: expense),
                      if (days.isEmpty) const _EmptyState(),
                      for (final d in days) ...[
                        _DayHeader(
                          day: d,
                          subtotal: groups[d]!.fold<int>(
                            0,
                            (a, e) => a + (e.isExpense ? _shown(e, me, ledger.defaultRatio) : -_shown(e, me, ledger.defaultRatio)),
                          ),
                        ),
                        Card(
                          child: Column(
                            children: [
                              for (final e in groups[d]!)
                                _EntryTile(
                                  entry: e,
                                  categories: categories,
                                  members: members,
                                  amount: _shown(e, me, ledger.defaultRatio),
                                  onTap: () => context.push('/entries/${e.id}'),
                                ),
                            ],
                          ),
                        ),
                      ],
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

class _MonthSummary extends StatelessWidget {
  const _MonthSummary({required this.income, required this.expense});
  final int income;
  final int expense;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget cell(String label, int value, Color color) => Expanded(
          child: Column(
            children: [
              Text(label, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              Text(fmtAmount(value),
                  style: t.textTheme.titleMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  )),
            ],
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Row(
          children: [
            cell('收入', income, incomeColor(context)),
            cell('支出', expense, t.colorScheme.onSurface),
            cell('損益', income - expense, income - expense < 0 ? t.colorScheme.error : incomeColor(context)),
          ],
        ),
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day, required this.subtotal});
  final DateTime day;
  final int subtotal;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final style = t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant, letterSpacing: 0.8);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(fmtDate(day), style: style),
          Text('小計 ${fmtAmount(subtotal)}',
              style: style?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.categories,
    required this.members,
    required this.amount,
    required this.onTap,
  });
  final Entry entry;
  final List<Category> categories;
  final List<Member> members;
  final int amount;
  final VoidCallback onTap;

  String _categoryName() {
    for (final c in categories) {
      if (c.id == entry.categoryId) return c.name;
    }
    return '未分類';
  }

  String _iconName() {
    for (final c in categories) {
      if (c.id == entry.categoryId) return c.icon;
    }
    return 'more_horiz';
  }

  String _memberName(String id) {
    for (final m in members) {
      if (m.id == id) return m.displayName;
    }
    return '成員';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final tags = <String>[
      if (entry.scope == EntryScope.private) '私人',
      if (entry.payerId != null && entry.splitMethod != SplitMethod.common) '代墊 ${_memberName(entry.payerId!)}',
      if (entry.settledState == SettledState.settling) '結算中',
      if (entry.settledState == SettledState.settled) '已結帳',
      if (entry.lineItems.isNotEmpty) '細項 ${entry.lineItems.length}',
    ];
    final title = entry.note.isEmpty ? _categoryName() : entry.note;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: t.colorScheme.surfaceContainerHighest,
              child: Icon(categoryIcon(_iconName()), size: 18, color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyLarge)),
                      if (entry.isAdjustment) ...[
                        const SizedBox(width: 6),
                        _Tag(text: '修正', tone: t.colorScheme.tertiary),
                      ],
                    ],
                  ),
                  if (tags.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [for (final x in tags) _Tag(text: x, tone: t.colorScheme.onSurfaceVariant)],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              entry.isExpense ? fmtAmount(amount) : '+${fmtAmount(amount)}',
              style: t.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: entry.isExpense ? t.colorScheme.onSurface : incomeColor(context),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.tone});
  final String text;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tone)),
    );
  }
}

/// 結算摘要小卡：一行摘要＋右側小按鈕，副標放筆數與簽核進度（整張高度 ≤ 72）。
class _SettlementBar extends StatelessWidget {
  const _SettlementBar({
    required this.icon,
    required this.summary,
    required this.detail,
    this.actionLabel,
    this.onAction,
  });

  /// 待簽核／結算中。
  factory _SettlementBar.pending({
    required Settlement settlement,
    required List<Member> members,
    required String me,
    required VoidCallback onApprove,
  }) {
    String name(String id) {
      for (final m in members) {
        if (m.id == id) return m.displayName;
      }
      return '成員';
    }

    final myNet = settlement.nets[me] ?? 0;
    final signers = settlement.requiredSigners;
    final needMe = signers.contains(me) && !settlement.approvedBy.contains(me);
    final signed = signers.where(settlement.approvedBy.contains).length;
    return _SettlementBar(
      icon: Icons.how_to_reg_outlined,
      summary: '${needMe ? '待你簽核' : '結算待簽核'} ${_netText(myNet)}',
      detail: '${name(settlement.initiatedBy)} 發起・${settlement.entryIds.length} 筆・簽核 $signed/${signers.length}',
      actionLabel: needMe ? '同意' : null,
      onAction: needMe ? onApprove : null,
    );
  }

  /// 可發起結算／已平衡。
  factory _SettlementBar.start({
    required Map<String, int> nets,
    required String me,
    required int count,
    required VoidCallback onStart,
  }) {
    final balanced = nets.values.every((v) => v == 0);
    final myNet = nets[me] ?? 0;
    return _SettlementBar(
      icon: balanced ? Icons.check_circle_outline : Icons.swap_horiz,
      summary: balanced ? '目前已平衡' : '代墊淨額 ${myNet >= 0 ? '+' : '-'}${fmtAmount(myNet.abs())}',
      detail: balanced ? '$count 筆代墊已互相抵銷' : '$count 筆待結算',
      actionLabel: balanced ? null : '發起',
      onAction: balanced ? null : onStart,
    );
  }

  static String _netText(int net) => net >= 0 ? '應收 ${fmtAmount(net)}' : '應付 ${fmtAmount(-net)}';

  final IconData icon;
  final String summary;
  final String detail;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: const Key('settlement-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
        child: Row(
          children: [
            Icon(icon, size: 20, color: t.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                  Text(detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            if (actionLabel != null) ...[
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(64, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64),
      child: Column(
        children: [
          Icon(Icons.receipt_long_outlined, size: 40, color: t.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text('這個月還沒有紀錄', style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text('點右下角「新增」記第一筆', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
