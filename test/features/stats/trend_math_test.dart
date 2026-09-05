import 'package:accounting/domain/models.dart';
import 'package:accounting/features/stats/trend_math.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// 固定小資料集（不吃 DateTime.now()），每個顆粒度的桶數與數值都寫死期望值
/// （v1.5／ADR-0009：無視角、無超支線，`spend`／`sharedBalance`／`topupByMember` 三欄）。
///
/// 帳目（全部共同錢包，`payerId` 恆 null）：
/// 3/1 收入 10000、3/5 支出 500＋200、3/12 支出 1000、2/10 支出 800。
void main() {
  const cFood = 'c1';
  const cIncome = 'i1';

  Entry exp(String id, int amt, DateTime on) => Entry(
        id: id,
        ledgerId: 'l',
        kind: EntryKind.expense,
        amount: amt,
        categoryId: cFood,
        occurredOn: on,
        createdBy: 'm',
      );

  Entry inc(String id, int amt, DateTime on) => Entry(
        id: id,
        ledgerId: 'l',
        kind: EntryKind.income,
        amount: amt,
        categoryId: cIncome,
        occurredOn: on,
        createdBy: 'm',
      );

  final entries = <Entry>[
    inc('i-1', 10000, DateTime(2026, 3, 1)),
    exp('e-1', 500, DateTime(2026, 3, 5)),
    exp('e-2', 200, DateTime(2026, 3, 5)),
    exp('e-3', 1000, DateTime(2026, 3, 12)),
    exp('e-4', 800, DateTime(2026, 2, 10)),
  ];

  final anchor = DateTime(2026, 3, 1);

  TrendInput input({
    List<Entry>? es,
    List<PersonalTopup> topups = const [],
    List<MonthClose> closes = const [],
  }) =>
      TrendInput(entries: es ?? entries, topups: topups, closes: closes);

  // 日期工具唯一定義處（`pie_card.dart` 只 import 不重寫，之前兩邊各放一份重複過）。
  group('日期工具（pie_card.dart 也共用這份定義）', () {
    test('startOfWeek 週一起算', () {
      // 2026-03-01 是週日 → 該週週一為 2026-02-23
      expect(startOfWeek(DateTime(2026, 3, 1)), DateTime(2026, 2, 23));
      expect(startOfWeek(DateTime(2026, 3, 2)), DateTime(2026, 3, 2));
      expect(endOfWeek(DateTime(2026, 3, 2)), DateTime(2026, 3, 8));
    });

    test('lastDayOfMonth 含閏年', () {
      expect(lastDayOfMonth(DateTime(2026, 2, 1)), DateTime(2026, 2, 28));
      expect(lastDayOfMonth(DateTime(2024, 2, 1)), DateTime(2024, 2, 29));
    });

    test('inRange 只比日期、皆含端點', () {
      expect(inRange(DateTime(2026, 3, 5, 23, 59), DateTime(2026, 3, 1), DateTime(2026, 3, 5)),
          isTrue);
      expect(inRange(DateTime(2026, 3, 6), DateTime(2026, 3, 1), DateTime(2026, 3, 5)), isFalse);
    });
  });

  group('spend／sharedBalance（無視角，v1.5）', () {
    test('日顆粒度：當月每日一桶', () {
      final b = bucketize(input(), Granularity.day, anchor);
      expect(b.length, 31);
      expect(b.first.label, '1');
      expect(b.last.label, '31');
      expect(b.first.start, DateTime(2026, 3, 1));
      expect(b.last.end, DateTime(2026, 3, 31));

      // 3/1：無支出，收入 10000，2/10 已花 800 → 累計餘額 9200
      expect(b[0].spend, 0);
      expect(b[0].sharedBalance, 9200);

      // 3/5：兩筆合計 700
      expect(b[4].spend, 700);
      expect(b[4].sharedBalance, 8500);

      // 3/12：1000
      expect(b[11].spend, 1000);
      expect(b[11].sharedBalance, 7500);

      // 月底無新帳：spend 是「這一天」的花費（0），但 sharedBalance 是累計水位，
      // 維持在 7500——若實作誤把 sharedBalance 算成「桶內淨變動」會在這裡紅成 0。
      expect(b.last.spend, 0, reason: '3/31 當天沒有新帳');
      expect(b.last.sharedBalance, 7500,
          reason: 'sharedBalance 是桶末累計水位，不是桶內淨變動；誤用淨變動這裡會紅成 0');
    });

    test('週顆粒度：最近 12 週', () {
      final w = bucketize(input(), Granularity.week, anchor);
      expect(w.length, 12);
      expect(w.last.start, DateTime(2026, 3, 30));
      expect(w.last.end, DateTime(2026, 4, 5));
      expect(w.last.label, '3/30');
      expect(w.first.start, DateTime(2026, 1, 12));
      expect(w.first.label, '1/12');
      expect(w.first.spend, 0);
      expect(w.first.sharedBalance, 0);

      final wk = w.firstWhere((x) => x.start == DateTime(2026, 3, 2));
      expect(wk.spend, 700);
      expect(wk.sharedBalance, 8500);

      final wk2 = w.firstWhere((x) => x.start == DateTime(2026, 3, 9));
      expect(wk2.spend, 1000);
      expect(wk2.sharedBalance, 7500);

      expect(w.last.spend, 0);
      expect(w.last.sharedBalance, 7500);
    });

    test('月顆粒度：最近 12 個月', () {
      final m = bucketize(input(), Granularity.month, anchor);
      expect(m.length, 12);
      expect(m.first.start, DateTime(2025, 4, 1));
      expect(m.last.start, DateTime(2026, 3, 1));
      expect(m.last.end, DateTime(2026, 3, 31));
      expect(m.last.label, '3月');
      expect(m.first.label, '4月');

      expect(m.last.spend, 1700);
      expect(m.last.sharedBalance, 7500);

      final feb = m.firstWhere((x) => x.start == DateTime(2026, 2, 1));
      expect(feb.spend, 800);
      expect(feb.sharedBalance, -800);

      final dec = m.firstWhere((x) => x.start == DateTime(2025, 12, 1));
      expect(dec.spend, 0);
      expect(dec.sharedBalance, 0);
    });

    test('年顆粒度：最近 5 年', () {
      final y = bucketize(input(), Granularity.year, anchor);
      expect(y.length, 5);
      expect(y.map((b) => b.label).toList(), ['2022', '2023', '2024', '2025', '2026']);
      expect(y.last.start, DateTime(2026, 1, 1));
      expect(y.last.end, DateTime(2026, 12, 31));

      expect(y.last.spend, 2500); // 800 + 1700
      expect(y.last.sharedBalance, 7500);
      expect(y[3].spend, 0);
    });

    test('不吃收入以外的付款人分岔：sharedBalance 只認 payerId==null 的支出（本組資料皆是）', () {
      // 換一筆有 payerId 的支出：不該再扣共同餘額（改扣該成員補入剩餘，那是
      // balance_math 的事，不是 trend_math 的事——這裡只驗 trend_math 呼叫的
      // 是同一顆 sharedBalance 函式，行為與 balance_math 單測一致）。
      final withAdvance = [
        ...entries,
        Entry(
          id: 'adv-1',
          ledgerId: 'l',
          kind: EntryKind.expense,
          amount: 999,
          categoryId: cFood,
          occurredOn: DateTime(2026, 3, 20),
          createdBy: 'm',
          payerId: 'someone',
        ),
      ];
      final m = bucketize(input(es: withAdvance), Granularity.month, anchor);
      expect(m.last.spend, 1700 + 999, reason: 'spend 不分誰付，全部支出都算');
      expect(m.last.sharedBalance, 7500, reason: '成員先付的支出不動共同餘額');
    });
  });

  group('topupByMember', () {
    final topups = [
      topupFixture(memberId: 'mem-a', amount: 10000, occurredOn: DateTime(2026, 3, 5)),
      topupFixture(memberId: 'mem-b', amount: 5000, occurredOn: DateTime(2026, 3, 10)),
      topupFixture(memberId: 'mem-a', amount: 3000, occurredOn: DateTime(2026, 2, 1)),
    ];

    test('月顆粒度：只算落在該月的補入，依成員分組', () {
      final m = bucketize(input(es: const [], topups: topups), Granularity.month, anchor);
      expect(m.last.topupByMember, {'mem-a': 10000, 'mem-b': 5000}, reason: '3 月桶');
      final feb = m.firstWhere((x) => x.start == DateTime(2026, 2, 1));
      expect(feb.topupByMember, {'mem-a': 3000});
      final dec = m.firstWhere((x) => x.start == DateTime(2025, 12, 1));
      expect(dec.topupByMember, isEmpty);
    });

    test('日／週顆粒度恆空 map：spec「只在月／年顆粒度畫」', () {
      final d = bucketize(input(es: const [], topups: topups), Granularity.day, anchor);
      expect(d.every((b) => b.topupByMember.isEmpty), isTrue,
          reason: '誤在日顆粒度也算 topupByMember 這裡會紅');

      final w = bucketize(input(es: const [], topups: topups), Granularity.week, anchor);
      expect(w.every((b) => b.topupByMember.isEmpty), isTrue,
          reason: '誤在週顆粒度也算 topupByMember 這裡會紅');
    });

    test('年顆粒度：該年各月加總（2/1 與 3/5 都在 2026 年）', () {
      final y = bucketize(input(es: const [], topups: topups), Granularity.year, anchor);
      final y2026 = y.firstWhere((x) => x.start == DateTime(2026, 1, 1));
      expect(y2026.topupByMember, {'mem-a': 3000 + 10000, 'mem-b': 5000});
      final y2025 = y.firstWhere((x) => x.start == DateTime(2025, 1, 1));
      expect(y2025.topupByMember, isEmpty);
    });

    test('已清月：月顆粒度讀 MonthClose.details 快照，不吃即時 topups', () {
      final closes = [
        closeFixture(
          month: DateTime(2026, 3, 1),
          members: [
            closeLine(memberId: 'mem-a', displayName: 'A', topup: 99999, paid: 0),
            closeLine(memberId: 'mem-b', displayName: 'B', topup: 77777, paid: 0),
          ],
        ),
      ];
      final m = bucketize(
        input(es: const [], topups: topups, closes: closes),
        Granularity.month,
        anchor,
      );
      // 3 月已清帳，快照值（99999／77777）刻意跟即時 topups（10000／5000）不同：
      // 若實作漏接快照、繼續加總即時 topups，這裡會紅成 {mem-a: 10000, mem-b: 5000}。
      expect(m.last.topupByMember, {'mem-a': 99999, 'mem-b': 77777});
      // 沒被清的 2 月不受影響，照樣讀即時 topups。
      final feb = m.firstWhere((x) => x.start == DateTime(2026, 2, 1));
      expect(feb.topupByMember, {'mem-a': 3000});
    });

    test('已清月：年顆粒度把該月的快照併入加總，不是整年都讀快照', () {
      final closes = [
        closeFixture(
          month: DateTime(2026, 3, 1),
          members: [closeLine(memberId: 'mem-a', displayName: 'A', topup: 99999, paid: 0)],
        ),
      ];
      final y = bucketize(
        input(es: const [], topups: topups, closes: closes),
        Granularity.year,
        anchor,
      );
      final y2026 = y.firstWhere((x) => x.start == DateTime(2026, 1, 1));
      // 2 月未清帳照舊讀即時 topups（3000）＋ 3 月已清帳讀快照（99999）＝102999；
      // mem-b 的補入落在 3 月、3 月已清帳且快照裡沒有 mem-b 這一行，所以 mem-b
      // 該年完全不出現（快照是那個月的唯一事實來源，不會回頭跟即時 topups 合併）。
      expect(y2026.topupByMember, {'mem-a': 3000 + 99999});
    });
  });
}
