import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

import '../../app/format.dart';
import '../../domain/models.dart';
import 'stats_card.dart';
import 'stats_colors.dart';
import 'trend_math.dart' show startOfWeek, endOfWeek, lastDayOfMonth;

/// 圓餅「週」模式的一段區間（皆含端點），已與該月取交集裁切。
typedef WeekRange = ({DateTime start, DateTime end});

/// 與 [month] 有交集的所有週（週一起算），**裁切到該月之內**依時間升冪。
///
/// 跨月的頭尾週只保留落在本月的那幾天：2026-02-23 那週在 3 月頁只剩 3/1 一天。
/// 不裁切的話，選「本月第一週」會把上個月的帳算進本月圓餅。
List<WeekRange> weekRangesOfMonth(DateTime month) {
  final m = DateTime(month.year, month.month, 1);
  final last = lastDayOfMonth(m);
  final out = <WeekRange>[];
  var w = startOfWeek(m);
  while (!w.isAfter(last)) {
    final e = endOfWeek(w);
    out.add((start: w.isBefore(m) ? m : w, end: e.isAfter(last) ? last : e));
    w = DateTime(w.year, w.month, w.day + 7);
  }
  return out;
}

/// 週 chip 的標籤：顯示裁切後的實際區間；只剩一天就不畫破折號。
String weekRangeLabel(WeekRange w) {
  final start = '${w.start.month}/${w.start.day}';
  if (w.start == w.end) return start;
  return '$start–${w.end.month}/${w.end.day}';
}

// ── 圓餅資料轉換（v1.5：無視角，直接吃 Entry；ADR-0009「統計」節）───────────

enum PieBy { category, payer }

/// 「依付款人」圓餅裡「共同錢包」那一項的 key（`payerId == null`）。
const kCommonWalletKey = '__common_wallet__';

/// 圓餅一塊：[key] 是 categoryId 或 memberId／[kCommonWalletKey]，標籤由 UI 解析。
typedef PieSlice = ({String key, int amount});

/// 只算支出，依金額降冪；合計 ≤ 0 的 key 不出現（修正筆可能讓某塊變負）。
///
/// [PieBy.payer] 是「依付款人」（v1.5 起無份額換算）：每位成員一片
/// （`payerId == m.id`）＋「共同錢包」一片（`payerId == null`）。
List<PieSlice> pieSlices(Iterable<Entry> entries, PieBy by) {
  final sums = <String, int>{};
  for (final e in entries) {
    if (!e.isExpense) continue;
    final key = switch (by) {
      PieBy.category => e.categoryId,
      PieBy.payer => e.fromCommonWallet ? kCommonWalletKey : e.payerId!,
    };
    sums[key] = (sums[key] ?? 0) + e.amount;
  }
  final out = <PieSlice>[
    for (final e in sums.entries)
      if (e.value > 0) (key: e.key, amount: e.value),
  ];
  out.sort((a, b) => b.amount.compareTo(a.amount));
  return out;
}

/// 圓餅區：依分類／依付款人 × 月／週，只算支出，下方圖例依金額降冪。
///
/// v1.5 無視角：「依分類」「依付款人」切換恆顯示（不再有個人視角關掉它的分支）。
class PieCard extends StatelessWidget {
  const PieCard({
    super.key,
    required this.periodLabel,
    required this.slices,
    required this.by,
    required this.onByChanged,
    required this.weekly,
    required this.onWeeklyChanged,
    required this.weeks,
    required this.week,
    required this.onWeekChanged,
    required this.labelFor,
    required this.colorIndexFor,
  });

  /// 副標顯示目前統計的期間；月模式為 null——「整月」已經寫在切換鍵上，
  /// 副標再寫一次既重複又會與切換文案撞名。
  final String? periodLabel;
  final List<PieSlice> slices;
  final PieBy by;
  final ValueChanged<PieBy> onByChanged;
  final bool weekly;
  final ValueChanged<bool> onWeeklyChanged;

  /// 已裁切到本月之內的週區間。
  final List<WeekRange> weeks;
  final WeekRange week;
  final ValueChanged<WeekRange> onWeekChanged;
  final String Function(String key) labelFor;

  /// key → 配色索引。用分類／成員的固定順序，不用切片名次，
  /// 否則同一個分類換個月排名變了就換色，也對不上趨勢「依分類」的線色。
  final int Function(String key) colorIndexFor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final total = slices.fold<int>(0, (a, s) => a + s.amount);

    return StatsCard(
      title: '支出分布',
      subtitle: periodLabel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<PieBy>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: PieBy.category, label: Text('分類')),
              ButtonSegment(value: PieBy.payer, label: Text('付款人')),
            ],
            selected: {by},
            onSelectionChanged: (s) => onByChanged(s.first),
          ),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('整月')),
              ButtonSegment(value: true, label: Text('單週')),
            ],
            selected: {weekly},
            onSelectionChanged: (s) => onWeeklyChanged(s.first),
          ),
          if (weekly) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final w in weeks)
                  ChoiceChip(
                    label: Text(weekRangeLabel(w)),
                    selected: w == week,
                    onSelected: (_) => onWeekChanged(w),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          // 圖區固定高度：沒資料時保留版位只換提示，切月／切週不會讓整頁跳動。
          SizedBox(
            height: kPieChartHeight,
            child: slices.isEmpty
                ? const StatsEmpty(message: '這個期間沒有支出')
                : SfCircularChart(
                    margin: EdgeInsets.zero,
                    series: [
                      DoughnutSeries<PieSlice, String>(
                        dataSource: slices,
                        // x 值用 key 不用顯示名稱：同名分類（設定頁可自由命名）
                        // 若拿名稱當 x，兩個分類會被併成同一片。
                        xValueMapper: (s, _) => s.key,
                        yValueMapper: (s, _) => s.amount,
                        // 內建 legend／tooltip 吃的是 x 值（也就是 key），
                        // 要讓它們顯示人看得懂的名稱只能走 dataLabelMapper。
                        dataLabelMapper: (s, _) => labelFor(s.key),
                        pointColorMapper: (s, _) => sliceColorAt(cs, colorIndexFor(s.key)),
                        innerRadius: '70%',
                        radius: '90%',
                        strokeWidth: 0,
                        animationDuration: 350,
                      ),
                    ],
                    annotations: [
                      CircularChartAnnotation(
                        widget: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('支出合計',
                                style: theme.textTheme.labelSmall
                                    ?.copyWith(color: cs.onSurfaceVariant)),
                            const SizedBox(height: 2),
                            Text(fmtAmount(total),
                                style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    fontFeatures: kTabularFigures)),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
          if (slices.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final s in slices)
              _LegendRow(
                color: sliceColorAt(cs, colorIndexFor(s.key)),
                label: labelFor(s.key),
                amount: s.amount,
              ),
          ],
        ],
      ),
    );
  }
}

/// 圓餅圖區固定高度（不含下方圖例列表）。
const double kPieChartHeight = 190;

class _LegendRow extends StatelessWidget {
  const _LegendRow({required this.color, required this.label, required this.amount});

  final Color color;
  final String label;
  final int amount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 78,
            child: Text(
              fmtAmount(amount),
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600, fontFeatures: kTabularFigures),
            ),
          ),
        ],
      ),
    );
  }
}
