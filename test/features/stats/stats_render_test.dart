import 'package:accounting/domain/models.dart';
import 'package:accounting/features/stats/pie_card.dart';
import 'package:accounting/features/stats/stats_colors.dart';
import 'package:accounting/features/stats/trend_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sliceColor', () {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF2F6F6D));

    test('黃金角步進：前 20 塊色相兩兩不撞（≥ 10 度）', () {
      final hues = [
        for (var i = 0; i < 20; i++) HSLColor.fromColor(sliceColor(scheme, i)).hue,
      ];
      for (var a = 0; a < hues.length; a++) {
        for (var b = a + 1; b < hues.length; b++) {
          final raw = (hues[a] - hues[b]).abs();
          final gap = raw > 180 ? 360 - raw : raw;
          expect(gap, greaterThanOrEqualTo(10.0),
              reason: '第 $a 與第 $b 塊色相只差 $gap 度');
        }
      }
    });

    test('深色主題用較亮的明度，兩者都在可讀區間', () {
      final dark = ColorScheme.fromSeed(
          seedColor: const Color(0xFF2F6F6D), brightness: Brightness.dark);
      for (var i = 0; i < 12; i++) {
        final l = HSLColor.fromColor(sliceColor(dark, i)).lightness;
        expect(l, inInclusiveRange(0.15, 0.85));
      }
      expect(
        HSLColor.fromColor(sliceColor(dark, 0)).lightness,
        greaterThan(HSLColor.fromColor(sliceColor(scheme, 0)).lightness),
      );
    });
  });

  group('axisNumberLabel', () {
    test('≥ 1 萬收成「萬」，≥ 10 萬不留小數，其餘整數', () {
      expect(axisNumberLabel(0), '0');
      expect(axisNumberLabel(850), '850');
      expect(axisNumberLabel(9999), '9999');
      expect(axisNumberLabel(12000), '1.2萬');
      expect(axisNumberLabel(154033), '15萬');
      expect(axisNumberLabel(-8888), '-8888');
      expect(axisNumberLabel(-12000), '-1.2萬');
    });
  });

  group('TrendLine', () {
    test('legend 順序固定，餘額預設收起、其餘預設展開', () {
      expect(TrendLine.values, [TrendLine.spend, TrendLine.over, TrendLine.balance]);
      expect(TrendLine.spend.initiallyVisible, isTrue);
      expect(TrendLine.over.initiallyVisible, isTrue);
      expect(TrendLine.balance.initiallyVisible, isFalse);
    });

    test('balance 標籤依視角變（v1.4，ADR-0008）：家庭「共同餘額」、個人「個人餘額」', () {
      expect(TrendLine.values.map((l) => l.labelFor(ViewMode.family)).toList(),
          ['花費', '超支', '共同餘額']);
      expect(TrendLine.values.map((l) => l.labelFor(ViewMode.personal)).toList(),
          ['花費', '超支', '個人餘額']);
    });
  });

  group('sliceColorAt', () {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF2F6F6D));

    test('索引 < 0 用中性灰，不退回第一個分類的顏色', () {
      expect(sliceColorAt(scheme, -1), scheme.outline);
      expect(sliceColorAt(scheme, -1), isNot(sliceColor(scheme, 0)));
      expect(sliceColorAt(scheme, -5), scheme.outline);
    });

    test('索引 >= 0 與 sliceColor 一致', () {
      for (var i = 0; i < 5; i++) {
        expect(sliceColorAt(scheme, i), sliceColor(scheme, i));
      }
    });
  });

  group('weekRangeLabel', () {
    test('完整週顯示區間；裁切成一天時不畫破折號', () {
      expect(
        weekRangeLabel((start: DateTime(2026, 3, 2), end: DateTime(2026, 3, 8))),
        '3/2–3/8',
      );
      expect(
        weekRangeLabel((start: DateTime(2026, 3, 1), end: DateTime(2026, 3, 1))),
        '3/1',
      );
      expect(
        weekRangeLabel((start: DateTime(2026, 3, 30), end: DateTime(2026, 3, 31))),
        '3/30–3/31',
      );
    });
  });
}
