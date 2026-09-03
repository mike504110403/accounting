/// 趨勢圖分桶純函式：把視角資料切成日／週／月／年桶，每桶算出花費、預算、超支、餘額。
library;

import '../../domain/budget_math.dart';
import '../../domain/models.dart';
import 'view_math.dart';

/// 一個時間桶（[start]、[end] 皆含端點）。
class Bucket {
  const Bucket({
    required this.label,
    required this.start,
    required this.end,
    required this.spend,
    required this.budget,
    required this.over,
    required this.balance,
  });

  /// x 軸標籤：日＝日數字、週＝M/d、月＝M月、年＝yyyy。
  final String label;
  final DateTime start;
  final DateTime end;

  /// 桶內支出合計（視角金額）。
  final int spend;

  /// 桶內有效上限合計；日桶＝該月合計／當月天數，週／年桶跨日（月）加總。
  final int budget;

  /// max(0, 花費 − 預算)。
  final int over;

  /// 桶末日的累計餘額。
  final int balance;
}

/// [bucketize] 的輸入。分成一包是因為預算線需要帳本層級的分類／預算，
/// 餘額線需要期初，全塞成位置參數會讓呼叫端難讀。
class TrendInput {
  const TrendInput({
    required this.items,
    required this.categories,
    required this.budgets,
    required this.rolloverBasis,
    required this.opening,
    this.budgetShare = 1.0,
  });

  /// 視角套用後的**全期間**資料（不要先過濾月份，餘額要往前累計）。
  final List<ViewEntry> items;

  /// 帳本分類；只有 `kind == expense` 的算進預算線。
  final List<Category> categories;

  /// 帳本預算。
  final List<Budget> budgets;

  /// rollover 遞推鏈的依據 entries（帳本層級的實際支出，與視角無關——
  /// 預算上限是帳本設定，不隨看家庭或個人而變）。
  final List<Entry> rolloverBasis;

  /// 該視角的期初餘額：家庭＝ledger.openingBalanceShared、個人＝member.openingBalancePersonal。
  final int opening;

  /// 預算線的視角折算比例：家庭＝1.0、個人＝我的 `default_ratio`（百分比／100）。
  ///
  /// 個人視角的花費線是「我的份額」，預算線不折算的話會拿半份花費去比整份上限，
  /// 超支線永遠偏低。折算後兩條線同口徑：我那份上限 vs 我那份花費。
  final double budgetShare;
}

/// 依顆粒度分桶。範圍固定：
/// 日＝[anchorMonth] 當月每日、週＝到當月最後一天所屬週為止的最近 12 週、
/// 月＝到 [anchorMonth] 為止的最近 12 個月、年＝到 anchorMonth.year 為止的最近 5 年。
List<Bucket> bucketize(TrendInput input, Granularity granularity, DateTime anchorMonth) {
  final ranges = _ranges(granularity, monthOf(anchorMonth));
  final balanceBasis = asEntries(input.items);
  final monthlyCache = <DateTime, double>{};

  // 折算與四捨五入分離：先全程用 double 累加，只在每個桶的最後 round 一次。
  double monthly(DateTime m) =>
      monthlyCache.putIfAbsent(monthOf(m), () => _monthlyBudget(input, m));

  final out = <Bucket>[];
  for (final r in ranges) {
    var spend = 0;
    for (final i in input.items) {
      if (!i.entry.isExpense) continue;
      if (!inRange(i.entry.occurredOn, r.start, r.end)) continue;
      spend += i.amount;
    }

    final budget = _budgetFor(granularity, r, monthly);

    out.add(Bucket(
      label: r.label,
      start: r.start,
      end: r.end,
      spend: spend,
      budget: budget,
      over: spend - budget > 0 ? spend - budget : 0,
      balance: runningBalance(opening: input.opening, entries: balanceBasis, until: r.end),
    ));
  }
  return out;
}

/// 每個支出分類各一組桶（趨勢圖「依分類」用），key 是 categoryId。
///
/// 桶的範圍與 [bucketize] 完全一致，只是花費與預算都收斂到單一分類。
/// **只有 `spend`、`budget`、`over` 有意義**：分類沒有「餘額」這回事
/// （餘額是帳本層級的期初＋收支累計），所以 `balance` 一律 0，UI 不得讀它。
Map<String, List<Bucket>> bucketizeByCategory(
  TrendInput input,
  Granularity granularity,
  DateTime anchorMonth,
) {
  final ranges = _ranges(granularity, monthOf(anchorMonth));
  final out = <String, List<Bucket>>{};

  for (final c in input.categories) {
    if (c.kind != EntryKind.expense) continue;

    final cache = <DateTime, double>{};
    double monthly(DateTime m) =>
        cache.putIfAbsent(monthOf(m), () => _categoryBudget(input, c, m));

    final list = <Bucket>[];
    for (final r in ranges) {
      var spend = 0;
      for (final i in input.items) {
        if (!i.entry.isExpense) continue;
        if (i.entry.categoryId != c.id) continue;
        if (!inRange(i.entry.occurredOn, r.start, r.end)) continue;
        spend += i.amount;
      }
      final budget = _budgetFor(granularity, r, monthly);
      list.add(Bucket(
        label: r.label,
        start: r.start,
        end: r.end,
        spend: spend,
        budget: budget,
        over: spend - budget > 0 ? spend - budget : 0,
        balance: 0, // 分類無餘額概念，見上方說明
      ));
    }
    out[c.id] = list;
  }
  return out;
}

int _budgetFor(Granularity g, _Range r, double Function(DateTime) monthly) => switch (g) {
      // 日與週都逐日累加「該月合計／當月天數」，跨月的週因此自動按各月天數攤。
      Granularity.day || Granularity.week => _sumDaily(r.start, r.end, monthly),
      Granularity.month => monthly(r.start).round(),
      Granularity.year => _sumYear(r.start.year, monthly),
    };

typedef _Range = ({DateTime start, DateTime end, String label});

List<_Range> _ranges(Granularity g, DateTime m) {
  final out = <_Range>[];
  switch (g) {
    case Granularity.day:
      final n = daysInMonth(m);
      for (var d = 1; d <= n; d++) {
        final day = DateTime(m.year, m.month, d);
        out.add((start: day, end: day, label: '$d'));
      }
    case Granularity.week:
      final lastStart = startOfWeek(lastDayOfMonth(m));
      for (var i = 11; i >= 0; i--) {
        final s = DateTime(lastStart.year, lastStart.month, lastStart.day - i * 7);
        out.add((start: s, end: endOfWeek(s), label: '${s.month}/${s.day}'));
      }
    case Granularity.month:
      for (var i = 11; i >= 0; i--) {
        final s = DateTime(m.year, m.month - i, 1);
        out.add((start: s, end: lastDayOfMonth(s), label: '${s.month}月'));
      }
    case Granularity.year:
      for (var i = 4; i >= 0; i--) {
        final y = m.year - i;
        out.add((start: DateTime(y, 1, 1), end: DateTime(y, 12, 31), label: '$y'));
      }
  }
  return out;
}

/// 該月所有支出分類的有效上限合計；沒預算的分類算 0。
///
/// 折算比例套在**每個分類的 effectiveLimit 之後、加總之前**：rollover 遞推鏈用的
/// 是帳本層級的完整上限（[TrendInput.rolloverBasis] 不折），先折半再遞推會讓
/// 「上月結餘」變成半份的半份。
double _monthlyBudget(TrendInput input, DateTime month) {
  var sum = 0.0;
  for (final c in input.categories) {
    if (c.kind != EntryKind.expense) continue;
    sum += _categoryBudget(input, c, month);
  }
  return sum;
}

/// 單一分類該月的有效上限（已套視角折算）；沒預算算 0。
double _categoryBudget(TrendInput input, Category c, DateTime month) {
  final limit = effectiveLimit(
        budgets: input.budgets,
        entries: input.rolloverBasis,
        category: c,
        month: month,
      ) ??
      0;
  return limit * input.budgetShare;
}

int _sumDaily(DateTime start, DateTime end, double Function(DateTime) monthly) {
  var acc = 0.0;
  var d = dateOnly(start);
  final stop = dateOnly(end);
  while (!d.isAfter(stop)) {
    acc += monthly(d) / daysInMonth(d);
    d = DateTime(d.year, d.month, d.day + 1);
  }
  return acc.round();
}

int _sumYear(int year, double Function(DateTime) monthly) {
  var sum = 0.0;
  for (var mm = 1; mm <= 12; mm++) {
    sum += monthly(DateTime(year, mm, 1));
  }
  return sum.round();
}
