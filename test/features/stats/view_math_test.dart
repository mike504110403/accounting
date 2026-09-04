import 'package:accounting/domain/balance_math.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/stats/trend_math.dart';
import 'package:accounting/features/stats/view_math.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;
  late List<Entry> entries;
  late Ledger ledger;

  setUp(() {
    container = ProviderContainer();
    entries = container.read(entriesProvider);
    ledger = container.read(ledgerProvider);
  });
  tearDown(() => container.dispose());

  List<ViewEntry> view(ViewMode mode, String me) =>
      viewEntries(entries, mode, me, ledger.defaultRatio);

  bool hasNote(List<ViewEntry> items, String note) =>
      items.any((i) => i.entry.note == note);

  group('viewEntries', () {
    test('個人視角：均分共同支出取我的份額（283.5 → 284）', () {
      final mine = view(ViewMode.personal, kMeId);
      final v = mine.firstWhere((i) => i.entry.note == '全聯買菜');
      expect(v.entry.amount, 567, reason: '主筆金額不變');
      expect(v.amount, 284, reason: '283.5 四捨五入');

      final hers = view(ViewMode.personal, kWifeId);
      expect(hers.firstWhere((i) => i.entry.note == '全聯買菜').amount, 284);
    });

    test('個人視角：common 錢包共同支出依 default_ratio 折半；共同收入不出現', () {
      final mine = view(ViewMode.personal, kMeId);
      expect(mine.firstWhere((i) => i.entry.note == '房租').amount, 13000);
      // 共同收入進共同餘額，不進個人視角（spec v1.3）。
      expect(hasNote(mine, '薪水'), isFalse);
    });

    test('私人筆只在本人的個人視角出現', () {
      expect(hasNote(view(ViewMode.personal, kMeId), 'Steam'), isTrue);
      expect(hasNote(view(ViewMode.personal, kWifeId), 'Steam'), isFalse);
      expect(hasNote(view(ViewMode.family, kMeId), 'Steam'), isFalse);
      // 私人收入同理
      expect(hasNote(view(ViewMode.personal, kMeId), '接案'), isTrue);
      expect(hasNote(view(ViewMode.family, kMeId), '接案'), isFalse);
    });

    test('settledState 不影響統計：settling 的支出照常計入', () {
      final settling =
          entries.where((e) => e.settledState == SettledState.settling).toList();
      expect(settling, isNotEmpty, reason: '假資料應有結算中的帳（e-6、e-7、e-9、e-10）');

      final fam = view(ViewMode.family, kMeId);
      final mine = view(ViewMode.personal, kMeId);
      for (final e in settling) {
        expect(fam.any((i) => i.entry.id == e.id), isTrue, reason: '家庭視角應含 ${e.note}');
        expect(mine.any((i) => i.entry.id == e.id), isTrue, reason: '個人視角應含 ${e.note}');
      }
      // 結算中的四筆共 1280+1520+420+680；全額進家庭視角
      expect(
        fam.where((i) => i.entry.settledState == SettledState.settling)
            .fold<int>(0, (a, i) => a + i.amount),
        3900,
      );
      // 個人視角取份額：640+760+210+340
      expect(
        mine.where((i) => i.entry.settledState == SettledState.settling)
            .fold<int>(0, (a, i) => a + i.amount),
        1950,
      );

      // pieSlices：結算中的四筆照常進圓餅，金額不打折
      final settlingSlices = pieSlices(
        fam.where((i) => i.entry.settledState == SettledState.settling),
        PieBy.category,
      );
      expect(
        {for (final x in settlingSlices) x.key: x.amount},
        {'c-daily': 1520, 'c-dining': 1280, 'c-food': 680, 'c-transport': 420},
      );

      // bucketize：本月桶的花費含這四筆（家庭視角本月支出合計 36467
      //   ＝26000 房租＋2300 電費＋567＋1280＋1520＋420＋680＋2400 大採購＋1300 週末外食）。
      // 這條測的是「settling 的帳有沒有正常進 spend」，balance 口徑不是重點，
      // 餵一個常數即可（真正的 v1.3 balance 口徑驗證在 monthSummary 那組測試）。
      final m = bucketize(
        TrendInput(
          items: fam,
          categories: container.read(categoriesProvider),
          balanceAt: (_) => 0,
          overspendAt: (_) => 0,
          categoryOverspendAt: (_, _) => 0,
        ),
        Granularity.month,
        DateTime.now(),
      );
      expect(m.last.spend, 36467);
    });

    test('家庭視角只取 shared 且金額全額', () {
      final fam = view(ViewMode.family, kMeId);
      expect(fam.every((i) => i.entry.scope == EntryScope.shared), isTrue);
      expect(fam.every((i) => i.amount == i.entry.amount), isTrue);
    });
  });

  group('monthSummary', () {
    test('家庭視角本月摘要與假資料手算一致（balance 改 v1.4 sharedBalance）', () {
      final s = monthSummary(
        items: view(ViewMode.family, kMeId),
        month: DateTime.now(),
        balance: sharedBalance(
            ledger: ledger, entries: entries, until: lastDayOfMonth(DateTime.now())),
      );
      // 收入：薪水 52000（私人接案 8000 不算）
      expect(s.income, 52000);
      // 支出：26000+2300+567+1280+1520+420+680+2400+1300（私人 Steam 350 不算）
      expect(s.expense, 36467);
      expect(s.net, 15533);
      // v1.4：balance 改吃 sharedBalance（月底），預算不再預扣。
      // 共同餘額＝期初 120000 ＋（本月 52000＋上月 52000）共同收入
      //   −（本月 26000+2300+2400+1300＋上月 26000+6200+3900+1100）共同錢包支出（payerId 為空）
      //   ＝154800（代墊的 567、1280、1520、420、680 走個人，不動共同餘額）。
      expect(s.balance, 154800);
    });

    test('個人視角本月摘要（Mike）與手算一致（balance 改 v1.4 personalBalance）', () {
      final me = container.read(membersProvider).firstWhere((m) => m.id == kMeId);
      final s = monthSummary(
        items: view(ViewMode.personal, kMeId),
        month: DateTime.now(),
        balance: personalBalance(
          member: me,
          entries: entries,
          closes: container.read(monthClosesProvider),
          until: lastDayOfMonth(DateTime.now()),
          joinedMonth: monthOf(me.joinedAt),
        ),
      );
      // 只有私人接案 8000（共同薪水進共同餘額，不進個人視角）
      expect(s.income, 8000);
      // 13000+1150+284+640+760+350+210+340+1200（大採購半）+650（週末外食半）
      expect(s.expense, 18584);
      expect(s.net, -10584);
      // v1.4：balance 改吃 personalBalance（月底，額度制）。
      // 補入額 10000 × 2 個未清帳月份（假資料的加入月＝上月）＝20000
      //   ＋ 私人收入 8000（接案）− 私人支出 350（Steam）
      //   − 未結算代墊全額 567（全聯 e-5，payerId Mike）− 1520（Costco e-7，payerId Mike）
      //   ＝25563（期初個人餘額已廢用；共同收支不動個人餘額）。
      expect(s.balance, 25563);
    });
  });

  group('pieSlices', () {
    List<ViewEntry> thisMonth(ViewMode mode) {
      final m = DateTime(DateTime.now().year, DateTime.now().month, 1);
      return view(mode, kMeId)
          .where((i) => inRange(i.entry.occurredOn, m, lastDayOfMonth(m)))
          .toList();
    }

    test('依分類：只算支出、依金額降冪', () {
      final s = pieSlices(thisMonth(ViewMode.family), PieBy.category);
      // c-food＝567+680+2400、c-dining＝1280+1300
      expect(s.map((x) => x.key).toList(),
          ['c-house', 'c-food', 'c-dining', 'c-util', 'c-daily', 'c-transport']);
      expect(s.map((x) => x.amount).toList(), [26000, 3647, 2580, 2300, 1520, 420]);
      expect(s.any((x) => x.key == 'c-salary'), isFalse, reason: '收入不進圓餅');
    });

    test('依成員：common 錢包歸「共同錢包」一項', () {
      final s = pieSlices(thisMonth(ViewMode.family), PieBy.member);
      expect(s.map((x) => x.key).toList(), [kCommonWalletKey, kWifeId, kMeId]);
      // 房租 26000 ＋ 電費 2300 ＋ 大採購 2400 ＋ 週末外食 1300 皆 common
      expect(s.first.amount, 32000);
      // 老婆：1280 + 420 + 680；Mike：567 + 1520
      expect(s[1].amount, 2380);
      expect(s[2].amount, 2087);
    });

    test('沒有支出時回空清單', () {
      expect(pieSlices(const [], PieBy.category), isEmpty);
    });
  });

  group('週工具', () {
    test('startOfWeek 週一起算', () {
      // 2026-03-01 是週日 → 該週週一為 2026-02-23
      expect(startOfWeek(DateTime(2026, 3, 1)), DateTime(2026, 2, 23));
      expect(startOfWeek(DateTime(2026, 3, 2)), DateTime(2026, 3, 2));
      expect(endOfWeek(DateTime(2026, 3, 2)), DateTime(2026, 3, 8));
    });

    test('weekRangesOfMonth 涵蓋整月每一週，且頭尾週裁切到月內', () {
      // 2026-03：頭週 2/23–3/1 裁成 3/1、尾週 3/30–4/5 裁成 3/30–3/31
      expect(weekRangesOfMonth(DateTime(2026, 3, 1)), [
        (start: DateTime(2026, 3, 1), end: DateTime(2026, 3, 1)),
        (start: DateTime(2026, 3, 2), end: DateTime(2026, 3, 8)),
        (start: DateTime(2026, 3, 9), end: DateTime(2026, 3, 15)),
        (start: DateTime(2026, 3, 16), end: DateTime(2026, 3, 22)),
        (start: DateTime(2026, 3, 23), end: DateTime(2026, 3, 29)),
        (start: DateTime(2026, 3, 30), end: DateTime(2026, 3, 31)),
      ]);
      // 每一段都必須完全落在該月內
      for (final w in weekRangesOfMonth(DateTime(2026, 2, 1))) {
        expect(w.start.month, 2);
        expect(w.end.month, 2);
        expect(w.start.isAfter(w.end), isFalse);
      }
    });

    test('裁切後的第一週不會把上個月的帳算進本月圓餅', () {
      // 2026-03 第一週只剩 3/1；2/28 的帳不該落在這段區間內
      final first = weekRangesOfMonth(DateTime(2026, 3, 1)).first;
      expect(inRange(DateTime(2026, 2, 28), first.start, first.end), isFalse);
      expect(inRange(DateTime(2026, 3, 1), first.start, first.end), isTrue);
    });

    test('lastDayOfMonth／daysInMonth 含閏年', () {
      expect(lastDayOfMonth(DateTime(2026, 2, 1)), DateTime(2026, 2, 28));
      expect(daysInMonth(DateTime(2024, 2, 1)), 29);
      expect(daysInMonth(DateTime(2026, 3, 1)), 31);
    });
  });
}
