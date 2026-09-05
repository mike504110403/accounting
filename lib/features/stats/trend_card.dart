import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

import '../../domain/models.dart';
import 'stats_card.dart';
import 'stats_colors.dart';
import 'trend_math.dart';

/// 圖區固定高度：沒資料時也保留版位，只是蓋一層提示，避免切顆粒度時整頁跳動。
const double kTrendChartHeight = 260;

/// 控制列高度。44 是 spec「UI 互動原則」的點擊目標底線，不因為是輔助開關就放寬。
const double kTrendToggleHeight = 44;

/// 趨勢卡一條線的規格：固定的花費／共同餘額兩條，加上依成員動態展開的補入線
/// （[_linesFor]）。用一個小物件而不是 enum，是因為補入線的數量跟著帳本成員走，
/// 不是編譯期就能列舉的固定集合。
class _Line {
  const _Line({
    required this.key,
    required this.label,
    required this.color,
    required this.valueOf,
    required this.initiallyVisible,
  });

  /// 切換狀態（`_hidden`）與 series key 用；成員線是 `'topup:$memberId'`。
  final String key;
  final String label;
  final Color color;
  final double Function(Bucket) valueOf;

  /// 餘額量級比其他線大一個數量級，同一 y 軸會把它們壓平，所以預設收起來。
  final bool initiallyVisible;
}

/// 這次趨勢圖要畫的線（spec「統計」節：花費、共同餘額、每人補入）。
///
/// 補入線**只在月／年顆粒度出現**（含 legend）：日／週顆粒度 `Bucket.topupByMember`
/// 恆空 map，出現一條恆為 0 的線與圖例只會讓人誤以為那個月／週真的沒人補入。
List<_Line> _linesFor(List<Member> members, Granularity granularity, ColorScheme cs) {
  final lines = <_Line>[
    _Line(
      key: 'spend',
      label: '花費',
      color: spendColor(cs),
      valueOf: (b) => b.spend.toDouble(),
      initiallyVisible: true,
    ),
    _Line(
      key: 'balance',
      label: '共同餘額',
      color: balanceColor(cs),
      valueOf: (b) => b.sharedBalance.toDouble(),
      initiallyVisible: false,
    ),
  ];
  if (granularity == Granularity.month || granularity == Granularity.year) {
    for (var i = 0; i < members.length; i++) {
      final m = members[i];
      lines.add(_Line(
        key: 'topup:${m.id}',
        label: '${m.displayName} 補入',
        color: memberColor(cs, i),
        valueOf: (b) => (b.topupByMember[m.id] ?? 0).toDouble(),
        initiallyVisible: true,
      ));
    }
  }
  return lines;
}

/// 趨勢區：顆粒度切換一列 ＋ 線別切換一列 ＋ 折線圖。
///
/// v1.5 無視角、無「各分類」檢視（超支與分類預算是預算頁的事，統計不再畫）。
class TrendCard extends StatefulWidget {
  const TrendCard({
    super.key,
    required this.buckets,
    required this.members,
    required this.granularity,
    required this.onGranularityChanged,
  });

  /// 花費／共同餘額／每人補入共用的桶。
  final List<Bucket> buckets;

  /// 帳本成員，順序即補入線的配色索引與 legend 順序。
  final List<Member> members;

  final Granularity granularity;
  final ValueChanged<Granularity> onGranularityChanged;

  @override
  State<TrendCard> createState() => _TrendCardState();
}

class _TrendCardState extends State<TrendCard> {
  late final TrackballBehavior _trackball;

  /// 被收起的線（key 見 [_Line.key]）。這是可見狀態的唯一來源。
  final Set<String> _hidden = {};

  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    // TrackballBehavior 的建構子有副作用（載入 marker 圖），只建一次。
    _trackball = TrackballBehavior(
      enable: true,
      activationMode: ActivationMode.singleTap,
      tooltipDisplayMode: TrackballDisplayMode.groupAllPoints,
      lineType: TrackballLineType.vertical,
    );
  }

  /// 預設可見性依 [_linesFor] 而定，但那需要 `Theme.of(context)`（拿 ColorScheme
  /// 只是為了配色，跟預設可見性無關，這裡用假 scheme 算一次初值即可），所以放
  /// [didChangeDependencies] 而不是 field initializer。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      final cs = Theme.of(context).colorScheme;
      for (final l in _linesFor(widget.members, widget.granularity, cs)) {
        if (!l.initiallyVisible) _hidden.add(l.key);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final lines = _linesFor(widget.members, widget.granularity, cs);
    final visibleLines = [for (final l in lines) if (!_hidden.contains(l.key)) l];
    final allHidden = visibleLines.isEmpty;
    final noData = widget.buckets.isEmpty ||
        widget.buckets.every((b) => lines.every((l) => l.valueOf(b) == 0));

    return StatsCard(
      title: '趨勢',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 第一列：顆粒度（v1.5 拿掉「總覽／各分類」tab，只剩這一組控制）。
          SizedBox(
            height: kTrendToggleHeight,
            child: SegmentedButton<Granularity>(
              key: const Key('trend-granularity'),
              showSelectedIcon: false,
              style: _compact,
              segments: const [
                ButtonSegment(value: Granularity.day, label: Text('日')),
                ButtonSegment(value: Granularity.week, label: Text('週')),
                ButtonSegment(value: Granularity.month, label: Text('月')),
                ButtonSegment(value: Granularity.year, label: Text('年')),
              ],
              selected: {widget.granularity},
              onSelectionChanged: (s) => widget.onGranularityChanged(s.first),
            ),
          ),
          const SizedBox(height: 8),
          // 第二列：線別切換。人數不定（不限人數），一律橫向捲動，超過寬度就滑。
          SizedBox(
            key: const Key('trend-toggles'),
            height: kTrendToggleHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: lines.length,
              separatorBuilder: (_, _) => const SizedBox(width: 4),
              itemBuilder: (_, i) {
                final l = lines[i];
                return _Toggle(
                  label: l.label,
                  color: l.color,
                  on: !_hidden.contains(l.key),
                  padded: true,
                  onTap: () => setState(() {
                    if (!_hidden.remove(l.key)) _hidden.add(l.key);
                  }),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: kTrendChartHeight,
            child: Stack(
              children: [
                Positioned.fill(child: _chart(cs, visibleLines)),
                if (noData) _overlay(theme, '這個範圍沒有資料'),
                if (!noData && allHidden) _overlay(theme, '請至少開啟一條線'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static const _compact = ButtonStyle(
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)),
    visualDensity: VisualDensity.compact,
  );

  Widget _overlay(ThemeData theme, String message) => Positioned.fill(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.88),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              message,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ),
      );

  SfCartesianChart _chart(ColorScheme cs, List<_Line> visible) {
    final buckets = widget.buckets;
    var lo = 0.0;
    for (final l in visible) {
      for (final b in buckets) {
        final v = l.valueOf(b);
        if (v < lo) lo = v;
      }
    }
    final labelStyle = TextStyle(fontSize: 10, color: cs.onSurfaceVariant);
    return SfCartesianChart(
      margin: const EdgeInsets.only(top: 4),
      plotAreaBorderWidth: 0,
      // 線別切換自己一列，不用內建 legend（390px 下它會換成兩排）。
      legend: const Legend(isVisible: false),
      trackballBehavior: _trackball,
      primaryXAxis: CategoryAxis(
        labelPlacement: LabelPlacement.onTicks,
        labelStyle: labelStyle,
        majorGridLines: const MajorGridLines(width: 0),
        majorTickLines: const MajorTickLines(size: 0),
        axisLine: AxisLine(width: 1, color: cs.outlineVariant),
        labelIntersectAction: AxisLabelIntersectAction.hide,
        // 日顆粒度每 7 天一標；其餘讓 Syncfusion 自動避讓。
        interval: widget.granularity == Granularity.day ? 7 : null,
        axisLabelFormatter: _xLabel,
      ),
      primaryYAxis: NumericAxis(
        // 全部非負時把下界釘在 0，免得軸自動留白跑出不存在的負刻度。
        minimum: lo >= 0 ? 0 : null,
        maximumLabels: 5,
        labelStyle: labelStyle,
        axisLine: const AxisLine(width: 0),
        majorTickLines: const MajorTickLines(size: 0),
        majorGridLines: MajorGridLines(width: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
        axisLabelFormatter: _yLabel,
      ),
      series: [
        for (final l in visible)
          LineSeries<Bucket, String>(
            dataSource: buckets,
            xValueMapper: (b, _) => b.label,
            yValueMapper: (b, _) => l.valueOf(b),
            name: l.label,
            color: l.color,
            width: 2.5,
            markerSettings: MarkerSettings(isVisible: buckets.length <= 12, height: 6, width: 6),
          ),
      ],
    );
  }

  /// x 軸標籤：日顆粒度只標 1、8、15、22（interval 7 會多帶出第 29 天，這裡消掉）。
  ChartAxisLabel _xLabel(AxisLabelRenderDetails d) {
    if (widget.granularity == Granularity.day && d.value > 21) {
      return ChartAxisLabel('', d.textStyle);
    }
    return ChartAxisLabel(d.text, d.textStyle);
  }

  ChartAxisLabel _yLabel(AxisLabelRenderDetails d) =>
      ChartAxisLabel(axisNumberLabel(d.value), d.textStyle);
}

/// 切換：色點＋標籤，選中實色、未選淡色。
class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.color,
    required this.on,
    required this.onTap,
    this.padded = false,
  });

  final String label;
  final Color color;
  final bool on;
  final VoidCallback onTap;

  /// 橫向捲動的切換列需要左右內距，等寬排列時不需要。
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: padded ? 8 : 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: on ? color : cs.outlineVariant,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: on ? cs.onSurface : cs.onSurfaceVariant.withValues(alpha: 0.6),
                  fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ≥ 1 萬顯示「1.2萬」（≥ 10 萬不留小數），否則整數。
String axisNumberLabel(num v) {
  final a = v.abs();
  if (a >= 10000) return '${(v / 10000).toStringAsFixed(a >= 100000 ? 0 : 1)}萬';
  return v.round().toString();
}
