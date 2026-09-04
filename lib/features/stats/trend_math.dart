/// 趨勢圖分桶純函式：把視角資料切成日／週／月／年桶，每桶算出花費、超支、可用餘額。
library;

import '../../domain/balance_math.dart';
import '../../domain/models.dart';
import 'view_math.dart';

/// 一個時間桶（[start]、[end] 皆含端點）。
class Bucket {
  const Bucket({
    required this.label,
    required this.start,
    required this.end,
    required this.spend,
    required this.over,
    required this.balance,
  });

  /// x 軸標籤：日＝日數字、週＝M/d、月＝M月、年＝yyyy。
  final String label;
  final DateTime start;
  final DateTime end;

  /// 桶內支出合計（視角金額），不分付款人與資金來源。
  final int spend;

  /// 桶末日的超支（家庭＝當月超支合計；個人視角沒有信封，恆 0）。
  final int over;

  /// 桶末日的可用餘額（家庭＝共同可用餘額、個人＝個人餘額）。
  final int balance;
}

/// [bucketize] 的輸入。
///
/// 餘額與超支不吃原始資料而吃兩個「算到某日」的函式（v1.3）：這兩條線的算式住在
/// `balance_math`，家庭與個人視角餵的參數也不同（共同可用餘額 vs 個人餘額）。
/// 由呼叫端把視角決定好包成函式，分桶這裡就只管切時間、不管帳務規則。
class TrendInput {
  const TrendInput({
    required this.items,
    required this.categories,
    required this.balanceAt,
    required this.overspendAt,
    required this.categoryOverspendAt,
  });

  /// 視角套用後的**全期間**資料（不要先過濾月份，花費以外的線要往前累計）。
  final List<ViewEntry> items;

  /// 帳本分類；只有 `kind == expense` 的有花費線。
  final List<Category> categories;

  /// 桶末日（含）的可用餘額。
  final int Function(DateTime until) balanceAt;

  /// 桶末日（含）的超支合計。
  final int Function(DateTime until) overspendAt;

  /// 桶末日（含）單一分類的超支（依分類版用）。
  final int Function(String categoryId, DateTime until) categoryOverspendAt;
}

/// 依顆粒度分桶。範圍固定：
/// 日＝[anchorMonth] 當月每日、週＝到當月最後一天所屬週為止的最近 12 週、
/// 月＝到 [anchorMonth] 為止的最近 12 個月、年＝到 anchorMonth.year 為止的最近 5 年。
List<Bucket> bucketize(TrendInput input, Granularity granularity, DateTime anchorMonth) {
  final ranges = _ranges(granularity, monthOf(anchorMonth));

  final out = <Bucket>[];
  for (final r in ranges) {
    var spend = 0;
    for (final i in input.items) {
      if (!i.entry.isExpense) continue;
      if (!inRange(i.entry.occurredOn, r.start, r.end)) continue;
      spend += i.amount;
    }

    out.add(Bucket(
      label: r.label,
      start: r.start,
      end: r.end,
      spend: spend,
      over: input.overspendAt(r.end),
      balance: input.balanceAt(r.end),
    ));
  }
  return out;
}

/// 每個支出分類各一組桶（趨勢圖「依分類」用），key 是 categoryId。
///
/// 桶的範圍與 [bucketize] 完全一致，花費與超支都收斂到單一分類。
/// **`balance` 一律 0**：分類沒有「餘額」這回事（餘額是帳本層級的期初＋收支累計），UI 不得讀它。
Map<String, List<Bucket>> bucketizeByCategory(
  TrendInput input,
  Granularity granularity,
  DateTime anchorMonth,
) {
  final ranges = _ranges(granularity, monthOf(anchorMonth));
  final out = <String, List<Bucket>>{};

  for (final c in input.categories) {
    if (c.kind != EntryKind.expense) continue;

    final list = <Bucket>[];
    for (final r in ranges) {
      var spend = 0;
      for (final i in input.items) {
        if (!i.entry.isExpense) continue;
        if (i.entry.categoryId != c.id) continue;
        if (!inRange(i.entry.occurredOn, r.start, r.end)) continue;
        spend += i.amount;
      }
      list.add(Bucket(
        label: r.label,
        start: r.start,
        end: r.end,
        spend: spend,
        over: input.categoryOverspendAt(c.id, r.end),
        balance: 0, // 分類無餘額概念，見上方說明
      ));
    }
    out[c.id] = list;
  }
  return out;
}

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
