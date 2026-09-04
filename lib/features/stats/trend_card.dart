import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

import '../../domain/models.dart';
import 'stats_card.dart';
import 'stats_colors.dart';
import 'trend_math.dart';

/// 趨勢卡的兩個檢視。
enum TrendTab { overview, byCategory }

/// 三條趨勢線（v1.3 拿掉預算線）。順序即切換列與 series 的順序。
///
/// 實際顯示的子集依視角而定（[_linesFor]）：家庭三條都畫，個人沒有信封所以
/// 沒有「超支」，只畫 [spend]／[balance]。
enum TrendLine { spend, over, balance }

extension TrendLineX on TrendLine {
  /// 字面不依視角變：家庭是共同可用餘額、個人是個人可用餘額，兩者都叫
  /// 「可用餘額」（spec：個人視角＝個人可用餘額）——與月摘要卡同一套用詞。
  String get label => switch (this) {
        TrendLine.spend => '花費',
        TrendLine.over => '超支',
        TrendLine.balance => '可用餘額',
      };

  Color color(ColorScheme cs) => switch (this) {
        TrendLine.spend => spendColor(cs),
        TrendLine.over => overColor(cs),
        TrendLine.balance => balanceColor(cs),
      };

  double valueOf(Bucket b) => switch (this) {
        TrendLine.spend => b.spend.toDouble(),
        TrendLine.over => b.over.toDouble(),
        TrendLine.balance => b.balance.toDouble(),
      };

  /// 餘額量級比其他兩條大一個數量級，同一 y 軸會把它們壓平，所以預設收起來。
  bool get initiallyVisible => this != TrendLine.balance;
}

/// 總覽線別依視角的子集：家庭三條都畫；個人沒有信封（超支恆 0），不給「超支」toggle。
/// 順序沿用 [TrendLine.values]，即切換列與 series 的順序。
List<TrendLine> _linesFor(ViewMode mode) => mode == ViewMode.personal
    ? const [TrendLine.spend, TrendLine.balance]
    : const [TrendLine.spend, TrendLine.over, TrendLine.balance];

/// 圖區固定高度：沒資料時也保留版位，只是蓋一層提示，避免切顆粒度時整頁跳動。
const double kTrendChartHeight = 260;

/// 控制列高度。44 是 spec「UI 互動原則」的點擊目標底線，不因為是輔助開關就放寬。
const double kTrendToggleHeight = 44;

/// 趨勢區：兩列控制（tab／顆粒度同列左右分置、線別切換自成一列）＋ 折線圖。
class TrendCard extends StatefulWidget {
  const TrendCard({
    super.key,
    required this.buckets,
    required this.byCategory,
    required this.expenseCategories,
    required this.granularity,
    required this.onGranularityChanged,
    required this.viewMode,
  });

  /// 總覽：三條線共用的桶（家庭）或兩條線共用的桶（個人——超支恆 0 但欄位仍在，不畫而已）。
  final List<Bucket> buckets;

  /// 依分類：categoryId → 該分類的桶。`spend` 與 `over`（該分類當月超支）有意義，
  /// `balance` 恆 0；目前的分類版圖只畫 `spend`。
  final Map<String, List<Bucket>> byCategory;

  /// 支出分類，**順序即配色索引**——與圓餅共用同一套 index，兩張圖同分類同色。
  final List<Category> expenseCategories;

  final Granularity granularity;
  final ValueChanged<Granularity> onGranularityChanged;

  /// 統計頁目前的視角：決定總覽線別子集（[_linesFor]）——個人沒有信封，
  /// 不畫「超支」。線的標籤字不依視角變（見 [TrendLineX.label]）。
  final ViewMode viewMode;

  @override
  State<TrendCard> createState() => _TrendCardState();
}

class _TrendCardState extends State<TrendCard> {
  late final TrackballBehavior _trackball;

  TrendTab _tab = TrendTab.overview;

  /// 總覽被收起的線。這是可見狀態的唯一來源（series 清單只放不在這裡面的）。
  /// 初值依 [TrendCard.viewMode] 而定，所以要在 [initState]（能讀 `widget`）設，
  /// 不能寫成欄位初始值（field initializer 跑在 `widget` 賦值之前）。
  late final Set<TrendLine> _hidden;

  /// 依分類被收起的分類，預設全開。
  final Set<String> _hiddenCats = {};

  @override
  void initState() {
    super.initState();
    _hidden = {
      for (final l in _linesFor(widget.viewMode))
        if (!l.initiallyVisible) l,
    };
    // TrackballBehavior 的建構子有副作用（載入 marker 圖），只建一次。
    _trackball = TrackballBehavior(
      enable: true,
      activationMode: ActivationMode.singleTap,
      tooltipDisplayMode: TrackballDisplayMode.groupAllPoints,
      lineType: TrackballLineType.vertical,
    );
  }

  @override
  void didUpdateWidget(TrendCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 分類可在設定頁刪除；殘留的 id 會讓「全部都關掉」的判斷永遠算不準。
    final ids = {for (final c in widget.expenseCategories) c.id};
    _hiddenCats.retainWhere(ids.contains);

    // 視角切換時線別集合會變（家庭三線／個人兩線，見 [_linesFor]）：不存在的線
    // 移出 `_hidden`（個人視角只剩兩條，`_hidden` 裡若還留著家庭獨有的「超支」，
    // 往後每次判斷都得多過濾一次不存在的殘留值，白白留一個陷阱）。
    // 家庭／個人唯一的差集只有 `over`，且 `over.initiallyVisible` 恆為 true，
    // 所以「新出現的線套預設可見性」這段補線邏輯永遠不會真的收起任何東西，
    // 是死碼——不寫，靠 `over` 重新出現時本來就不在 `_hidden` 裡即可（它剛剛才
    // 被上面這行移除）。
    _hidden.retainWhere(_linesFor(widget.viewMode).contains);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final overview = _tab == TrendTab.overview;

    final visibleLines = [
      for (final l in _linesFor(widget.viewMode))
        if (!_hidden.contains(l)) l,
    ];
    final visibleCats = [
      for (final c in widget.expenseCategories)
        if (!_hiddenCats.contains(c.id)) c,
    ];
    final allHidden = overview ? visibleLines.isEmpty : visibleCats.isEmpty;
    final noData = overview ? _overviewEmpty() : _categoryEmpty();

    return StatsCard(
      title: '趨勢',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 第一列：檢視 tab 在左、顆粒度在右（資訊密度：三列併成兩列）。
          SizedBox(
            height: kTrendToggleHeight,
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: SegmentedButton<TrendTab>(
                    key: const Key('trend-tab'),
                    showSelectedIcon: false,
                    style: _compact,
                    segments: const [
                      ButtonSegment(
                          value: TrendTab.overview,
                          label: Text('總覽', maxLines: 1, softWrap: false)),
                      ButtonSegment(
                          value: TrendTab.byCategory,
                          label: Text('各分類', maxLines: 1, softWrap: false)),
                    ],
                    selected: {_tab},
                    onSelectionChanged: (s) => setState(() => _tab = s.first),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 6,
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
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 第二列：線別／分類切換。
          SizedBox(
            key: const Key('trend-toggles'),
            height: kTrendToggleHeight,
            child: overview ? _lineToggles(cs) : _categoryToggles(cs),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: kTrendChartHeight,
            child: Stack(
              children: [
                Positioned.fill(
                  child: overview
                      ? _overviewChart(cs, visibleLines)
                      : _categoryChart(cs, visibleCats),
                ),
                if (noData) _overlay(theme, '這個範圍沒有資料'),
                if (!noData && allHidden)
                  _overlay(theme, overview ? '請至少開啟一條線' : '請至少開啟一個分類'),
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

  // 只看視角實際會畫的線（[_linesFor]）：個人視角沒有超支線，over 是否為 0
  // 不該影響「這個範圍有沒有資料」的判斷（雖然個人視角 over 現況恆 0，這裡仍
  // 明確依線別子集判斷，不靠這個巧合）。
  bool _overviewEmpty() =>
      widget.buckets.isEmpty ||
      widget.buckets.every((b) => _linesFor(widget.viewMode).every((l) => l.valueOf(b) == 0));

  // 分類版畫的只有花費線，所以「有沒有資料」只看 spend。
  bool _categoryEmpty() =>
      widget.byCategory.values.every((list) => list.every((b) => b.spend == 0));

  Widget _lineToggles(ColorScheme cs) => Row(
        children: [
          for (final l in _linesFor(widget.viewMode))
            Expanded(
              child: _Toggle(
                label: l.label,
                color: l.color(cs),
                on: !_hidden.contains(l),
                onTap: () => setState(() {
                  if (!_hidden.remove(l)) _hidden.add(l);
                }),
              ),
            ),
        ],
      );

  /// 分類數量不定（設定頁可無限新增），一律橫向捲動，超過寬度就滑。
  Widget _categoryToggles(ColorScheme cs) => ListView.separated(
        key: const Key('trend-category-toggles'),
        scrollDirection: Axis.horizontal,
        itemCount: widget.expenseCategories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (_, i) {
          final c = widget.expenseCategories[i];
          return _Toggle(
            label: c.name,
            color: sliceColor(cs, i),
            on: !_hiddenCats.contains(c.id),
            padded: true,
            onTap: () => setState(() {
              if (!_hiddenCats.remove(c.id)) _hiddenCats.add(c.id);
            }),
          );
        },
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

  SfCartesianChart _overviewChart(ColorScheme cs, List<TrendLine> visible) {
    final buckets = widget.buckets;
    var lo = 0.0;
    for (final l in visible) {
      for (final b in buckets) {
        if (l.valueOf(b) < lo) lo = l.valueOf(b);
      }
    }
    return _chart(cs, lo, [
      for (final l in visible)
        LineSeries<Bucket, String>(
          dataSource: buckets,
          xValueMapper: (b, _) => b.label,
          yValueMapper: (b, _) => l.valueOf(b),
          name: l.label,
          color: l.color(cs),
          width: 2.5,
          markerSettings: MarkerSettings(isVisible: buckets.length <= 12, height: 6, width: 6),
        ),
    ]);
  }

  SfCartesianChart _categoryChart(ColorScheme cs, List<Category> visible) {
    // 每個分類的桶數一致（共用同一份 ranges），取任一個即可；
    // 不要靠迴圈最後一圈覆寫 —— 全部分類都關掉時那個值會是 0。
    final points = widget.byCategory.isEmpty ? 0 : widget.byCategory.values.first.length;
    var lo = 0.0;
    for (final c in visible) {
      for (final b in widget.byCategory[c.id] ?? const <Bucket>[]) {
        if (b.spend < lo) lo = b.spend.toDouble();
      }
    }
    return _chart(cs, lo, [
      for (final c in visible)
        LineSeries<Bucket, String>(
          dataSource: widget.byCategory[c.id] ?? const <Bucket>[],
          xValueMapper: (b, _) => b.label,
          yValueMapper: (b, _) => b.spend.toDouble(),
          name: c.name,
          color: sliceColor(cs, widget.expenseCategories.indexOf(c)),
          width: 2,
          markerSettings: MarkerSettings(isVisible: points <= 12, height: 5, width: 5),
        ),
    ]);
  }

  SfCartesianChart _chart(ColorScheme cs, double lo, List<LineSeries<Bucket, String>> series) {
    final labelStyle = TextStyle(fontSize: 10, color: cs.onSurfaceVariant);
    return SfCartesianChart(
      margin: const EdgeInsets.only(top: 4),
      plotAreaBorderWidth: 0,
      // 線別／分類切換自己一列，不用內建 legend（390px 下它會換成兩排）。
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
      series: series,
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

  /// 橫向捲動的分類切換需要左右內距，等寬的線別切換不需要。
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
