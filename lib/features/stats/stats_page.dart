import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/format.dart';
import '../../app/month_app_bar.dart';
import '../../domain/balance_math.dart';
import '../../data/month_summary_provider.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import 'pie_card.dart';
import 'stats_card.dart';
import 'trend_card.dart';
import 'trend_math.dart';
import 'view_math.dart';

/// 統計頁：月摘要、支出圓餅、三條趨勢線；家庭／個人兩視角（ADR-0003、ADR-0007）。
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
    final allocations = ref.watch(allocationsProvider);
    final settlements = ref.watch(settlementsProvider);

    Member? found;
    for (final m in members) {
      if (m.id == me) found = m;
    }
    // final 才能在下面的 closure 裡吃到型別提升（非 final 的區域變數在 closure 內不提升）。
    final meMember = found;

    final personal = _mode == ViewMode.personal;
    final items = viewEntries(entries, _mode, me, ledger.defaultRatio);

    // 可用餘額（ADR-0007，v1.3）：家庭＝共同可用餘額、個人＝個人可用餘額。
    // 月摘要與趨勢的餘額線吃同一個函式，避免兩處各自判斷視角、算出兩套答案。
    final int Function(DateTime until) balanceAt = personal
        ? (until) => meMember == null
            ? 0
            : personalAvailable(
                member: meMember,
                entries: entries,
                settlements: settlements,
                until: until,
              )
        : (until) => sharedAvailable(
              ledger: ledger,
              entries: entries,
              allocations: allocations,
              until: until,
            );

    // 月摘要卡的可用餘額改吃 DB month_summary（Mike 裁示 2026-09-03）；趨勢線的
    // 逐桶餘額仍是前端依 server 列現算（逐桶打 RPC 成本過高，已記驗證債）。
    final server = ref.watch(monthSummaryProvider(lastDayOfMonth(_month))).value;
    final int Function(DateTime until) cardBalanceAt = server == null
        ? balanceAt
        : (_) => personal ? (server.personalBalance ?? 0) : server.sharedAvailable;
    final summary = monthSummary(items: items, month: _month, balanceAt: cardBalanceAt);

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

    // 超支線的視角差異（ADR-0007）：家庭＝當月超支合計；個人沒有信封，恆 0。
    // 餘額線與月摘要共用上面算好的 balanceAt。
    final trendInput = TrendInput(
      items: items,
      categories: categories,
      balanceAt: balanceAt,
      overspendAt: personal
          ? (_) => 0
          : (until) => totalOverspend(
                entries: entries,
                allocations: allocations,
                until: until,
              ),
      categoryOverspendAt: personal
          ? (_, _) => 0
          : (categoryId, until) => overspend(
                allocations: allocations,
                entries: entries,
                categoryId: categoryId,
                until: until,
              ),
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
              viewMode: _mode,
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
      // 兩行各兩格（Mike 裁示 2026-09-03）：上行收入／支出、下行損益／可用餘額。
      child: Column(
        key: const Key('month-summary'),
        children: [
          Row(
            children: [
              _Figure(label: '收入', value: summary.income, color: cs.primary),
              _Figure(label: '支出', value: summary.expense, color: cs.error),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _Figure(
                label: '損益',
                value: summary.net,
                color: summary.net >= 0 ? cs.primary : cs.error,
              ),
              // 標籤字只留一份：直接借趨勢餘額線的 label，不依視角變（個人視角也是
              // 「個人可用餘額」），兩處同字用同一個 source，不會各自漂移。
              _Figure(label: TrendLine.balance.label, value: summary.balance, color: cs.onSurface),
            ],
          ),
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
