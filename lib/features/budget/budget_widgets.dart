/// 預算頁的純呈現元件（版面沿用 v1.3）：只吃已算好的數字，不碰 provider、不呼叫 balance_math。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/category_icon.dart';
import '../../app/format.dart';
import '../../domain/models.dart';

/// 波浪動畫只在真 app 開：widget test 的 binding 不是 [WidgetsFlutterBinding]，
/// 永不停的波浪會讓 pumpAndSettle 逾時，測試一律走靜態填充。
bool get _wavesEnabled => WidgetsBinding.instance is WidgetsFlutterBinding;

/// 金額數字用等寬數字（tabular figures），對齊卡片間的欄位；style 為 null 時仍套用（併入 Text 的 ambient 樣式）。
TextStyle tabularStyle([TextStyle? style]) =>
    (style ?? const TextStyle()).merge(const TextStyle(fontFeatures: [FontFeature.tabularFigures()]));

/// 一個分類在該月的預算狀態（畫面層資料，算式仍在 `balance_math`）。
class CategoryRowData {
  const CategoryRowData({
    required this.category,
    required this.allocated,
    required this.spent,
    required this.remaining,
    required this.over,
  });

  final Category category;

  /// 當月預算（v1.4：每分類每月一筆）。
  final int allocated;

  /// 當月該分類的所有共同支出（不分 payer）。
  final int spent;
  final int remaining;
  final int over;

  /// 沒預算也沒共同支出：顯示「未設定」，不畫三個數字與進度條（仍可點開 sheet）。
  bool get noActivity => allocated == 0 && spent == 0;
}

/// 頂部摘要卡（v1.5／ADR-0009，四格）：共同餘額大字；第二列本月預算合計／本月支出／
/// 本月超支（0 時顯示「—」不上紅）。
class SummaryCard extends StatelessWidget {
  const SummaryCard({
    super.key,
    required this.sharedBalance,
    required this.budgetTotal,
    required this.spentTotal,
    required this.overspendTotal,
  });

  /// 共同餘額＝Σ共同收入 − Σ共同錢包支出（v1.5 起無期初餘額）。
  final int sharedBalance;

  /// 本月所有分類的預算合計。
  final int budgetTotal;

  /// 本月**全部**支出合計（不分共同錢包付或成員先付）。
  final int spentTotal;
  final int overspendTotal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('共同餘額', style: textTheme.bodySmall),
            Text(
              fmtMoney(sharedBalance),
              style: tabularStyle(textTheme.headlineMedium?.copyWith(color: sharedBalance < 0 ? scheme.error : null)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _stat(context, '本月預算合計', fmtMoney(budgetTotal))),
                Expanded(child: _stat(context, '本月支出', fmtMoney(spentTotal))),
                Expanded(
                  child: _stat(
                    context,
                    '本月超支',
                    overspendTotal > 0 ? fmtMoney(overspendTotal) : '—',
                    color: overspendTotal > 0 ? scheme.error : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(BuildContext context, String label, String value, {Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        // 金額不能用省略號截斷（Mike 裁示：截斷會讓人看錯錢）——三欄版面在六位數金額
        // 下縮字級頂住，不犧牲位數。`SizedBox(width: infinity)` 給 FittedBox 一個確定
        // 寬度可以縮放，`alignment: centerLeft` 配合 Column 的 `crossAxisAlignment.start`。
        SizedBox(
          width: double.infinity,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: tabularStyle(Theme.of(context).textTheme.titleMedium?.copyWith(color: color)),
            ),
          ),
        ),
      ],
    );
  }
}

/// 「設定本月預算」提示：只在當月／未來月且該月完全沒有任何預算時由呼叫端決定是否顯示
/// （spec 口徑）。[canCopy] 與 [busy] 刻意分開：[canCopy] 為 false（上月也沒有預算可複製）
/// 決定文字換成「上月沒有預算」，[busy]（複製進行中）只影響按鈕是否 disabled、不影響文字
/// ——複製正在跑的時候明明有東西可複製，不能被誤判成「上月沒有預算」。
class SetBudgetPrompt extends StatelessWidget {
  const SetBudgetPrompt({super.key, required this.canCopy, required this.busy, required this.onCopy});
  final bool canCopy;
  final bool busy;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                canCopy ? '設定本月預算' : '上月沒有預算',
                style: Theme.of(context).textTheme.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              key: const Key('copy-last-month-btn'),
              onPressed: (canCopy && !busy) ? onCopy : null,
              child: const Text('複製上月'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分類水位長條（Mike 手測回饋 2026-09-03：卡片換長條圖、一目瞭然、要水位動畫）。
/// 整列是一根橫向長條：填充寬度＝剩餘／預算（預算還剩多少水，花錢水位下降），
/// 超支＝滿條錯誤色；水位變化用 [TweenAnimationBuilder] 補間（首繪從 0 漲到位）。
/// 條上左 icon＋名稱、右主行「剩餘／超支＋金額」與次行「已花・預算」；未設定畫空條灰字。
class CategoryRow extends StatelessWidget {
  const CategoryRow({super.key, required this.row, required this.onTap});
  final CategoryRowData row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final category = row.category;
    final over = row.over > 0;
    final level = over
        ? 1.0
        : row.allocated > 0
            ? (row.remaining / row.allocated).clamp(0.0, 1.0)
            : 0.0;
    final secondary = textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);

    return ClipRRect(
      key: ValueKey('category-row-${category.id}'),
      borderRadius: BorderRadius.circular(14),
      child: Material(
        color: scheme.surfaceContainerHigh,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 52,
            child: Stack(
              fit: StackFit.expand,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: level),
                  duration: const Duration(milliseconds: 800),
                  curve: Curves.easeOutCubic,
                  builder: (_, v, _) => _wavesEnabled
                      // 真 app：自寫雙層水波（Mike 調參 2026-09-03：晃動頻率低、波形細）。
                      ? _WaveFill(
                          value: v,
                          color: over ? scheme.errorContainer : scheme.primaryContainer,
                          seed: category.id.hashCode,
                        )
                      // widget test：波浪動畫永不停會卡死 pumpAndSettle，改用靜態填充
                      //（測試斷言的 water-fill key／widthFactor 走這條路）。
                      : Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: v,
                            heightFactor: 1,
                            child: ColoredBox(
                              key: ValueKey('water-fill-${category.id}'),
                              color: over ? scheme.errorContainer : scheme.primaryContainer,
                            ),
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      Icon(categoryIcon(category.icon), size: 20, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(category.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.titleSmall),
                      ),
                      const SizedBox(width: 8),
                      if (row.noActivity)
                        Text('未設定', style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant))
                      else if (row.allocated == 0)
                        // 沒設預算但本月已有支出（v1.5 seed 目前沒有這個組合，widget test
                        // 用自造 fixture 覆蓋）：仍要標「未設定」——這不是「設了預算又花超」，
                        // 是「根本沒設」；但已花不可藏（spec：已花＝全部支出，不分誰付，含
                        // 沖銷後的負數淨額，一樣不能假裝沒發生）；超支只在
                        // over > 0 才畫——沖銷把這個分類的當月淨額沖成 0 或負數時，
                        // balance_math 把 over 夾在 0，這裡不畫一行「超支 0」誤導人。
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('未設定', style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                            if (row.spent != 0 || row.over > 0)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (row.spent != 0) ...[
                                    Text('已花', style: secondary),
                                    const SizedBox(width: 4),
                                    Text(fmtAmount(row.spent), style: tabularStyle(secondary)),
                                  ],
                                  if (row.spent != 0 && row.over > 0) const SizedBox(width: 8),
                                  if (row.over > 0) ...[
                                    Text('超支', style: secondary?.copyWith(color: scheme.error)),
                                    const SizedBox(width: 4),
                                    Text(fmtAmount(row.over), style: tabularStyle(secondary?.copyWith(color: scheme.error))),
                                  ],
                                ],
                              ),
                          ],
                        )
                      else
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(over ? '超支' : '剩餘',
                                    style: textTheme.bodySmall
                                        ?.copyWith(color: over ? scheme.error : scheme.onSurfaceVariant)),
                                const SizedBox(width: 5),
                                Text(
                                  fmtAmount(over ? row.over : row.remaining),
                                  style: tabularStyle(textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600, color: over ? scheme.error : null)),
                                ),
                              ],
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('已花', style: secondary),
                                const SizedBox(width: 4),
                                Text(fmtAmount(row.spent), style: tabularStyle(secondary)),
                                const SizedBox(width: 8),
                                Text('預算', style: secondary),
                                const SizedBox(width: 4),
                                Text(fmtAmount(row.allocated), style: tabularStyle(secondary)),
                              ],
                            ),
                          ],
                        ),
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

/// 水位的雙層波浪填充（取代 liquid_progress_indicator_v2：波形參數寫死且太粗獷）。
/// 參數（Mike 調參 2026-09-03 第二輪）：週期約 4 秒（晃動慢）、振幅 6.5/9px、波長 44px（顆粒大），
/// 背景層半透明錯相位有深度；[seed]（分類 id）決定每條的相位與週期微差——
/// 各晃各的、不整排同步。只在真 app 使用（見 [_wavesEnabled]）。
class _WaveFill extends StatefulWidget {
  const _WaveFill({required this.value, required this.color, required this.seed});

  /// 填充比例 0..1（水位）。
  final double value;
  final Color color;
  final int seed;

  @override
  State<_WaveFill> createState() => _WaveFillState();
}

class _WaveFillState extends State<_WaveFill> with SingleTickerProviderStateMixin {
  // 週期 3.4–5.0 秒之間依 seed 取值：頻率有些微差異，逐漸自然錯開。
  late final AnimationController _controller = AnimationController(
      vsync: this, duration: Duration(milliseconds: 3400 + widget.seed.abs() % 1600))
    ..repeat();

  /// 起始相位也吃 seed：一進頁面就不同步，不用等頻率差慢慢拉開。
  late final double _phaseOffset = (widget.seed.abs() % 628) / 100.0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, _) {
        final phase = _controller.value * 2 * math.pi + _phaseOffset;
        return Stack(
          fit: StackFit.expand,
          children: [
            _layer(phase: phase, amplitude: 9, opacity: 0.45),
            _layer(phase: phase + math.pi / 1.5, amplitude: 6.5, opacity: 1),
          ],
        );
      },
    );
  }

  Widget _layer({required double phase, required double amplitude, required double opacity}) {
    return ClipPath(
      clipper: _WaveClipper(value: widget.value, phase: phase, amplitude: amplitude, wavelength: 44),
      child: ColoredBox(color: widget.color.withValues(alpha: opacity)),
    );
  }
}

class _WaveClipper extends CustomClipper<Path> {
  const _WaveClipper({
    required this.value,
    required this.phase,
    required this.amplitude,
    required this.wavelength,
  });

  final double value;
  final double phase;
  final double amplitude;
  final double wavelength;

  @override
  Path getClip(Size size) {
    final fillX = size.width * value;
    final path = Path()..moveTo(0, 0);
    // 水面是填充的右緣（垂直邊）：沿高度每 2px 取一點畫 sin 波。
    for (double y = 0; y <= size.height; y += 2) {
      final x = (fillX + amplitude * math.sin(2 * math.pi * y / wavelength + phase))
          .clamp(0.0, size.width);
      path.lineTo(x, y);
    }
    path
      ..lineTo(0, size.height)
      ..close();
    return path;
  }

  @override
  bool shouldReclip(_WaveClipper old) =>
      old.phase != phase || old.value != value || old.amplitude != amplitude;
}
