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
import 'stats_colors.dart' show kMemberColorOffset;
import 'trend_card.dart';
import 'trend_math.dart';

/// 統計頁：月摘要、支出圓餅、趨勢線（v1.5／ADR-0009：無視角）。
///
/// 三組線（花費、共同餘額、每人補入）與圓餅（依分類、依付款人）都不再有
/// 家庭／個人切換——`entries` 一律是全部家庭支出＋共同收入，不需要視角過濾。
class StatsPage extends ConsumerStatefulWidget {
  const StatsPage({super.key});

  @override
  ConsumerState<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends ConsumerState<StatsPage> {
  late DateTime _month = monthOf(DateTime.now());
  PieBy _pieBy = PieBy.category;
  bool _weekly = false;
  DateTime? _week;
  Granularity _granularity = Granularity.month;

  void _setMonth(DateTime m) => setState(() {
        _month = DateTime(m.year, m.month, 1);
        _week = null; // 換月後週選擇重算，不沿用上個月的那一週
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
    final members = ref.watch(membersProvider);
    final categories = ref.watch(categoriesProvider);
    final entries = ref.watch(entriesProvider);
    final topups = ref.watch(topupsProvider);
    final closes = ref.watch(monthClosesProvider);

    // 月摘要卡永遠是「月」層級。
    final cardUntil = lastDayOfMonth(_month);

    // 月摘要卡的餘額改吃 DB month_summary（Mike 裁示 2026-09-03）；server 還沒回應
    // （或測試沒接 monthSummaryProvider）時 fallback 前端本地公式，跟趨勢線同一套
    // balance_math.sharedBalance，兩邊不會對不起來。
    final server = ref.watch(monthSummaryProvider(cardUntil)).value;
    final int balance = server?.sharedBalance ?? sharedBalance(entries: entries, until: cardUntil);

    // 支出改用 balance_math.totalSpent（跟預算頁「本月支出」同一顆函式，口徑
    // 不會各自漂移）；收入沒有對應的共用函式（totalSpent 只算支出），照舊手算。
    var income = 0;
    for (final e in entries) {
      if (e.isExpense) continue;
      if (!sameMonth(e.occurredOn, _month)) continue;
      income += e.amount;
    }
    final expense = totalSpent(entries: entries, until: cardUntil);

    final weeks = weekRangesOfMonth(_month);
    final week = _resolveWeek(weeks);
    final pieStart = _weekly ? week.start : _month;
    final pieEnd = _weekly ? week.end : lastDayOfMonth(_month);
    final slices = pieSlices(
      entries.where((e) => inRange(e.occurredOn, pieStart, pieEnd)),
      _pieBy,
    );

    // 順序即配色索引：圓餅與趨勢用同一套，同分類同色且不隨金額排序而變。
    final expenseCats = [
      for (final c in categories)
        if (c.kind == EntryKind.expense) c,
    ];

    final buckets = bucketize(
      TrendInput(entries: entries, topups: topups, closes: closes),
      _granularity,
      _month,
    );

    return Scaffold(
      // 與帳目頁共用同一個頂部列：月份標題的高度、間距、位置完全一致。
      appBar: MonthAppBar(month: _month, onMonthChanged: _setMonth),
      body: _Centered(
        child: ListView(
          key: const Key('stats-list'),
          // 左右留白由 theme 的 cardTheme.margin（h16）提供，這裡只給上下。
          padding: const EdgeInsets.fromLTRB(0, 10, 0, 32),
          children: [
            _SummaryCard(income: income, expense: expense, net: income - expense, balance: balance),
            PieCard(
              // 月模式不給副標：期間就是 AppBar 那個月，而「整月」已寫在切換鍵上。
              periodLabel: _weekly ? weekRangeLabel(week) : null,
              slices: slices,
              by: _pieBy,
              onByChanged: (v) => setState(() => _pieBy = v),
              weekly: _weekly,
              onWeeklyChanged: (v) => setState(() => _weekly = v),
              weeks: weeks,
              week: week,
              onWeekChanged: (w) => setState(() => _week = w.start),
              labelFor: (key) => _labelFor(key, _pieBy, categories, members),
              colorIndexFor: (key) => _colorIndexFor(key, _pieBy, expenseCats, members),
            ),
            TrendCard(
              buckets: buckets,
              members: members,
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

  /// 配色索引：分類用支出分類的固定順序；依付款人的成員片跟趨勢卡「補入」線
  /// 共用同一顆 [memberColor]（同一人同色，兩張卡對得起來）——`sliceColorAt(cs, i)`
  /// 對 i ≥ 0 就是 `sliceColor(cs, i)`，這裡直接把 `memberColor` 的 `+4` offset
  /// 內建進回傳的索引，PieCard 那邊不必知道這個位移。
  /// 共同錢包片刻意回 -1（[sliceColorAt] 的中性灰路徑）：跟任何分類、任何成員都
  /// 不會撞色，也不用另外發明一個顏色常數。
  /// 找不到（查不到分類／成員）一樣回 -1，不退回 0，免得和第一個分類撞色。
  int _colorIndexFor(String key, PieBy by, List<Category> expenseCats, List<Member> members) {
    if (by == PieBy.category) {
      return expenseCats.indexWhere((c) => c.id == key);
    }
    if (key == kCommonWalletKey) return -1;
    final i = members.indexWhere((m) => m.id == key);
    return i < 0 ? -1 : i + kMemberColorOffset;
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
  const _SummaryCard({
    required this.income,
    required this.expense,
    required this.net,
    required this.balance,
  });

  final int income;
  final int expense;
  final int net;

  /// 共同餘額（`balance_math.sharedBalance`，清帳不動它——ADR-0009）。
  final int balance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return StatsCard(
      title: '月摘要',
      // 兩行各兩格：上行收入／支出、下行損益／共同餘額。
      child: Column(
        key: const Key('month-summary'),
        children: [
          Row(
            children: [
              _Figure(label: '收入', value: income, color: cs.primary),
              _Figure(label: '支出', value: expense, color: cs.error),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _Figure(label: '損益', value: net, color: net >= 0 ? cs.primary : cs.error),
              _Figure(label: '共同餘額', value: balance, color: cs.onSurface),
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
