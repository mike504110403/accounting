import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

import '../../app/format.dart';
import 'stats_card.dart';
import 'stats_colors.dart';
import 'view_math.dart';

/// 圓餅區：依分類／依成員 × 月／週，只算支出，下方圖例依金額降冪。
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
    this.showByToggle = true,
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

  /// 個人視角關掉「依成員」：那裡的成員是 payer（誰墊的），
  /// 金額卻是我的份額，兩者混用會被讀成「這個人花了我這麼多」。
  final bool showByToggle;

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
          if (showByToggle) ...[
            SegmentedButton<PieBy>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: PieBy.category, label: Text('分類')),
                ButtonSegment(value: PieBy.member, label: Text('成員')),
              ],
              selected: {by},
              onSelectionChanged: (s) => onByChanged(s.first),
            ),
            const SizedBox(height: 8),
          ],
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

/// 週 chip 的標籤：顯示裁切後的實際區間；只剩一天就不畫破折號。
String weekRangeLabel(WeekRange w) {
  final start = '${w.start.month}/${w.start.day}';
  if (w.start == w.end) return start;
  return '$start–${w.end.month}/${w.end.day}';
}

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
