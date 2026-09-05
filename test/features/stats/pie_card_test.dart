import 'package:accounting/domain/models.dart';
import 'package:accounting/features/stats/pie_card.dart';
import 'package:accounting/features/stats/trend_math.dart' show inRange;
import 'package:flutter_test/flutter_test.dart';

/// [pieSlices]／週期間工具的純函式測試（v1.5：無視角，直接吃 [Entry]；
/// `view_math.dart` 已刪，這些原本住在那邊）。
///
/// `startOfWeek`／`endOfWeek`／`lastDayOfMonth`／`inRange`／`dateOnly` 唯一定義
/// 處是 `trend_math.dart`（`pie_card.dart` 只 import 不重寫），這幾個原子函式的
/// 單測住在 `trend_math_test.dart`；這裡只測 `weekRangesOfMonth`（真的是
/// `pie_card.dart` 自己的組合邏輯）與 `pieSlices`。
void main() {
  Entry exp(String id, int amt, {String cat = 'c-food', String? payerId}) => Entry(
        id: id,
        ledgerId: 'l',
        kind: EntryKind.expense,
        amount: amt,
        categoryId: cat,
        occurredOn: DateTime(2026, 3, 10),
        createdBy: 'mike',
        payerId: payerId,
      );

  group('pieSlices', () {
    test('依分類：只算支出、依金額降冪，合計 ≤0 的 key 不出現', () {
      final entries = [
        exp('e-1', 300, cat: 'c-food'),
        exp('e-2', 700, cat: 'c-dining'),
        exp('e-3', 200, cat: 'c-food'),
        Entry(
          id: 'e-void',
          ledgerId: 'l',
          kind: EntryKind.expense,
          amount: -500,
          categoryId: 'c-void',
          occurredOn: DateTime(2026, 3, 1),
          createdBy: 'mike',
        ), // 沖銷筆讓某分類變負：不該出現
        Entry(
          id: 'i-1',
          ledgerId: 'l',
          kind: EntryKind.income,
          amount: 999,
          categoryId: 'c-salary',
          occurredOn: DateTime(2026, 3, 1),
          createdBy: 'mike',
        ), // 收入不進圓餅
      ];
      final s = pieSlices(entries, PieBy.category);
      expect(s.map((x) => x.key).toList(), ['c-dining', 'c-food']);
      expect(s.map((x) => x.amount).toList(), [700, 500]);
      expect(s.any((x) => x.key == 'c-void'), isFalse);
      expect(s.any((x) => x.key == 'c-salary'), isFalse);
    });

    test('依付款人：每位成員一片＋「共同錢包」一片（payerId==null）', () {
      final entries = [
        exp('e-mike-1', 4000, payerId: 'mike'),
        exp('e-mike-2', 2000, payerId: 'mike'),
        exp('e-wife-1', 2000, payerId: 'wife'),
        exp('e-common-1', 3000, payerId: null),
      ];
      final s = pieSlices(entries, PieBy.payer);
      // 誤把「共同錢包」漏掉（例如漏接 fromCommonWallet 分支）這裡會少一片、
      // 且 3000 會憑空消失，總金額對不起來。
      expect(s.map((x) => x.key).toSet(), {'mike', 'wife', kCommonWalletKey});
      expect(s.firstWhere((x) => x.key == 'mike').amount, 6000);
      expect(s.firstWhere((x) => x.key == 'wife').amount, 2000);
      expect(s.firstWhere((x) => x.key == kCommonWalletKey).amount, 3000);
    });

    test('沒有支出時回空清單', () {
      expect(pieSlices(const [], PieBy.category), isEmpty);
      final onlyIncome = [
        Entry(
          id: 'i-1',
          ledgerId: 'l',
          kind: EntryKind.income,
          amount: 999,
          categoryId: 'c-salary',
          occurredOn: DateTime(2026, 3, 1),
          createdBy: 'mike',
        ),
      ];
      expect(pieSlices(onlyIncome, PieBy.payer), isEmpty);
    });
  });

  group('週工具', () {
    test('weekRangesOfMonth 涵蓋整月每一週，且頭尾週裁切到月內', () {
      expect(weekRangesOfMonth(DateTime(2026, 3, 1)), [
        (start: DateTime(2026, 3, 1), end: DateTime(2026, 3, 1)),
        (start: DateTime(2026, 3, 2), end: DateTime(2026, 3, 8)),
        (start: DateTime(2026, 3, 9), end: DateTime(2026, 3, 15)),
        (start: DateTime(2026, 3, 16), end: DateTime(2026, 3, 22)),
        (start: DateTime(2026, 3, 23), end: DateTime(2026, 3, 29)),
        (start: DateTime(2026, 3, 30), end: DateTime(2026, 3, 31)),
      ]);
      for (final w in weekRangesOfMonth(DateTime(2026, 2, 1))) {
        expect(w.start.month, 2);
        expect(w.end.month, 2);
        expect(w.start.isAfter(w.end), isFalse);
      }
    });

    test('裁切後的第一週不會把上個月的帳算進本月圓餅', () {
      final first = weekRangesOfMonth(DateTime(2026, 3, 1)).first;
      expect(inRange(DateTime(2026, 2, 28), first.start, first.end), isFalse);
      expect(inRange(DateTime(2026, 3, 1), first.start, first.end), isTrue);
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
    });
  });
}
