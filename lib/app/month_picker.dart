import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'format.dart';

/// 底部彈窗選年月（手機 app 慣例）：年份與月份兩個獨立直立滾輪並排；
/// 點彈窗外＝關閉並套用目前滾到的值；「本月」快捷。回傳該月 1 號（永不為 null）。
Future<DateTime> showMonthPicker(BuildContext context, DateTime initial) async {
  var year = initial.year;
  var month = initial.month;
  final now = DateTime.now();
  final years = [for (var y = 2015; y <= now.year + 1; y++) y];

  final result = await showModalBottomSheet<DateTime>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final brightness = Theme.of(ctx).brightness;
      final style = Theme.of(ctx).textTheme.titleMedium;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text('選擇月份', style: Theme.of(ctx).textTheme.titleSmall),
                  const Spacer(),
                  TextButton(
                    key: const Key('month-picker-today'),
                    onPressed: () => Navigator.pop(ctx, DateTime(now.year, now.month, 1)),
                    child: const Text('本月'),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 200,
              child: CupertinoTheme(
                data: CupertinoThemeData(brightness: brightness),
                child: Row(
                  children: [
                    Expanded(
                      child: CupertinoPicker(
                        key: const Key('month-picker-year'),
                        itemExtent: 40,
                        scrollController: FixedExtentScrollController(initialItem: years.indexOf(year).clamp(0, years.length - 1)),
                        onSelectedItemChanged: (i) => year = years[i],
                        children: [for (final y in years) Center(child: Text('$y 年', style: style))],
                      ),
                    ),
                    Expanded(
                      child: CupertinoPicker(
                        key: const Key('month-picker-month'),
                        itemExtent: 40,
                        scrollController: FixedExtentScrollController(initialItem: month - 1),
                        onSelectedItemChanged: (i) => month = i + 1,
                        children: [for (var m = 1; m <= 12; m++) Center(child: Text('$m 月', style: style))],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  // 點彈窗外或下滑關閉 → result 為 null → 套用目前滾到的值。
  return result ?? DateTime(year, month, 1);
}

/// AppBar 用的月份標題：左右箭頭快速切上／下月；點標題開年月彈窗；標題左右滑亦可切月。
class MonthTitle extends StatelessWidget {
  const MonthTitle({super.key, required this.month, required this.onChanged});
  final DateTime month;
  final ValueChanged<DateTime> onChanged;

  void _shift(int delta) => onChanged(DateTime(month.year, month.month + delta, 1));

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('month-prev'),
          tooltip: '上個月',
          visualDensity: VisualDensity.compact,
          onPressed: () => _shift(-1),
          icon: const Icon(Icons.chevron_left),
        ),
        GestureDetector(
          key: const Key('month-title'),
          behavior: HitTestBehavior.opaque,
          onTap: () async {
            final r = await showMonthPicker(context, month);
            if (r.year != month.year || r.month != month.month) onChanged(r);
          },
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v < -200) _shift(1);
            if (v > 200) _shift(-1);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(fmtMonth(month), style: Theme.of(context).textTheme.titleMedium),
                const Icon(Icons.expand_more, size: 20),
              ],
            ),
          ),
        ),
        IconButton(
          key: const Key('month-next'),
          tooltip: '下個月',
          visualDensity: VisualDensity.compact,
          onPressed: () => _shift(1),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}
