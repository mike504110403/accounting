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

  group('memberColor', () {
    test('N 位成員兩兩不同色，且都不等於共同錢包的中性灰', () {
      final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF2F6F6D));
      // 6 位涵蓋比常見兩人多的情境，人數不限也該撐得住。
      final colors = [for (var i = 0; i < 6; i++) memberColor(scheme, i)];
      final commonWallet = sliceColorAt(scheme, -1); // 圓餅「共同錢包」片用的顏色
      for (var a = 0; a < colors.length; a++) {
        expect(colors[a], isNot(commonWallet),
            reason: '第 $a 位成員不該跟共同錢包（中性灰）同色');
        for (var b = a + 1; b < colors.length; b++) {
          expect(colors[a], isNot(colors[b]), reason: '第 $a 與第 $b 位成員撞色');
        }
      }
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
}
