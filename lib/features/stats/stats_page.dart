import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/format.dart';
import '../../app/month_app_bar.dart';
import '../../domain/budget_math.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import 'pie_card.dart';
import 'stats_card.dart';
import 'trend_card.dart';
import 'trend_math.dart';
import 'view_math.dart';

/// 統計頁：月摘要、支出圓餅、四條趨勢線；家庭／個人兩視角（ADR-0003）。
class StatsPage extends ConsumerStatefulWidget {
  const StatsPage({super.key});

  @override
  ConsumerState<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends ConsumerState<StatsPage> {
  late DateTime _month = monthOf(DateTime.now());
  ViewMode _mode = ViewMode.family;
  PieBy _pieBy = PieBy.category;
  bool _weekly = false;
  DateTime? _week;
  Granularity _granularity = Granularity.month;

  void _setMonth(DateTime m) => setState(() {
        _month = DateTime(m.year, m.month, 1);
        _week = null; // 換月後週選擇重算，不沿用上個月的那一週
      });

  void _setMode(ViewMode m) => setState(() {
        _mode = m;
        // 個人視角沒有「依成員」：state 一併拉回，免得切回家庭時
        // 冒出一個使用者在個人視角根本看不到、也沒選過的選擇。
        if (m == ViewMode.personal) _pieBy = PieBy.category;
      });

  /// 目前選到的那一週；沒選過就用含今天的那一週（本月不含今天時退回該月第一週）。
  WeekRange _resolveWeek(List<WeekRange> weeks) {
    final picked = _week;
    if (picked != null) {
      for (final w in weeks) {
        if (w.start == picked) return w;
      }
    }
    final today = dateOnly(DateTime.now());
    for (final w in weeks) {
      if (inRange(today, w.start, w.end)) return w;
    }
    return weeks.first;
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider);
    final me = ref.watch(currentMemberIdProvider);
    final members = ref.watch(membersProvider);
    final categories = ref.watch(categoriesProvider);
    final entries = ref.watch(entriesProvider);
    final budgets = ref.watch(budgetsProvider);

    Member? meMember;
    for (final m in members) {
      if (m.id == me) meMember = m;
    }

    final personal = _mode == ViewMode.personal;
    final items = viewEntries(entries, _mode, me, ledger.defaultRatio);
    final opening = personal
        ? (meMember?.openingBalancePersonal ?? 0)
        : ledger.openingBalanceShared;
    // 個人視角的花費是我的份額，預算線同步折算成我的份額上限。
    final budgetShare = personal ? (ledger.defaultRatio[me] ?? 0) / 100.0 : 1.0;

    final summary = monthSummary(items: items, month: _month, opening: opening);

    final weeks = weekRangesOfMonth(_month);
    final week = _resolveWeek(weeks);
    final pieStart = _weekly ? week.start : _month;
    final pieEnd = _weekly ? week.end : lastDayOfMonth(_month);
    // 個人視角只能依分類（依成員的 payer 歸戶與份額金額混用會誤讀）。
    final pieBy = personal ? PieBy.category : _pieBy;
    final slices = pieSlices(
      items.where((i) => inRange(i.entry.occurredOn, pieStart, pieEnd)),
      pieBy,
    );

    // 順序即配色索引：圓餅與趨勢用同一套，同分類同色且不隨金額排序而變。
    final expenseCats = [
      for (final c in categories)
        if (c.kind == EntryKind.expense) c,
    ];

    final trendInput = TrendInput(
      items: items,
      categories: categories,
      budgets: budgets,
      // 預算上限是帳本設定，rollover 鏈一律用共同帳的實際支出算，不隨視角變。
      rolloverBasis: entries.where((e) => e.scope == EntryScope.shared).toList(),
      opening: opening,
      budgetShare: budgetShare,
    );
    final buckets = bucketize(trendInput, _granularity, _month);
    final byCategory = bucketizeByCategory(trendInput, _granularity, _month);

    return Scaffold(
      // 與帳目頁共用同一個頂部列：月份標題與視角切換的高度、間距、位置完全一致。
      appBar: MonthAppBar(
        month: _month,
        onMonthChanged: _setMonth,
        view: _mode,
        onViewChanged: _setMode,
      ),
      body: _Centered(
        child: ListView(
          // 左右留白由 theme 的 cardTheme.margin（h16）提供，這裡只給上下。
          padding: const EdgeInsets.fromLTRB(0, 10, 0, 32),
          children: [
            _SummaryCard(summary: summary),
            PieCard(
              // 月模式不給副標：期間就是 AppBar 那個月，而「整月」已寫在切換鍵上。
              periodLabel: _weekly ? weekRangeLabel(week) : null,
              slices: slices,
              by: pieBy,
              onByChanged: (v) => setState(() => _pieBy = v),
              showByToggle: !personal,
              weekly: _weekly,
              onWeeklyChanged: (v) => setState(() => _weekly = v),
              weeks: weeks,
              week: week,
              onWeekChanged: (w) => setState(() => _week = w.start),
              labelFor: (key) => _labelFor(key, pieBy, categories, members),
              colorIndexFor: (key) => _colorIndexFor(key, pieBy, expenseCats, members),
            ),
            TrendCard(
              buckets: buckets,
              byCategory: byCategory,
              expenseCategories: expenseCats,
              granularity: _granularity,
              onGranularityChanged: (v) => setState(() => _granularity = v),
            ),
          ],
        ),
      ),
    );
  }

  String _labelFor(String key, PieBy by, List<Category> categories, List<Member> members) {
    if (by == PieBy.category) {
      for (final c in categories) {
        if (c.id == key) return c.name;
      }
      return '未分類';
    }
    if (key == kCommonWalletKey) return '共同錢包';
    for (final m in members) {
      if (m.id == key) return m.displayName;
    }
    return '未知成員';
  }

  /// 配色索引：分類用支出分類的固定順序、成員用成員順序（共同錢包排 0）。
  /// 不用「圓餅切片名次」當索引——那會讓同一個分類換個月就換色。
  /// 查不到回 -1，由 [sliceColorAt] 給中性灰（不退回 0，免得和第一個分類撞色）。
  int _colorIndexFor(String key, PieBy by, List<Category> expenseCats, List<Member> members) {
    if (by == PieBy.category) {
      return expenseCats.indexWhere((c) => c.id == key);
    }
    if (key == kCommonWalletKey) return 0;
    final i = members.indexWhere((m) => m.id == key);
    return i < 0 ? -1 : i + 1;
  }
}

/// 桌面寬度不爆版：內容置中並限寬 560。
class _Centered extends StatelessWidget {
  const _Centered({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: child),
      );
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final MonthSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return StatsCard(
      title: '月摘要',
      // 資訊密度：一列四格數字，不加說明文字。
      child: Row(
        key: const Key('month-summary'),
        children: [
          _Figure(label: '收入', value: summary.income, color: cs.primary),
          _Figure(label: '支出', value: summary.expense, color: cs.error),
          _Figure(
            label: '損益',
            value: summary.net,
            color: summary.net >= 0 ? cs.primary : cs.error,
          ),
          _Figure(label: '餘額', value: summary.balance, color: cs.onSurface),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, required this.color});

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              fmtAmount(value),
              style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700, color: color, fontFeatures: kTabularFigures),
            ),
          ),
        ],
      ),
    );
  }
}
