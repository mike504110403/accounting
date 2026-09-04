/// `month_summary` RPC 的回傳形狀（migration 20260903000200）。
/// 畫面上的衍生數字（餘額／信封／超支）由 DB 依 Supabase 資料計算（Mike 裁示 2026-09-03），
/// 客戶端只解析顯示；`InMemoryLedgerRepository` 用 balance_math 算出同形狀供測試與 USE_MOCK。
library;

class EnvelopeSummary {
  const EnvelopeSummary({
    required this.categoryId,
    required this.allocated,
    required this.spent,
    required this.remaining,
    required this.over,
  });

  factory EnvelopeSummary.fromJson(Map<String, dynamic> json) => EnvelopeSummary(
        categoryId: json['category_id'] as String,
        allocated: (json['allocated'] as num).toInt(),
        spent: (json['spent'] as num).toInt(),
        remaining: (json['remaining'] as num).toInt(),
        over: (json['over'] as num).toInt(),
      );

  final String categoryId;
  final int allocated;
  final int spent;
  final int remaining;
  final int over;
}

class MonthSummary {
  const MonthSummary({
    required this.sharedBalance,
    required this.sharedAvailable,
    required this.envelopeTotal,
    required this.overspendTotal,
    required this.categories,
    this.memberId,
    this.personalBalance,
  });

  factory MonthSummary.fromJson(Map<String, dynamic> json) {
    final me = json['me'] as Map<String, dynamic>?;
    return MonthSummary(
      sharedBalance: (json['shared_balance'] as num).toInt(),
      sharedAvailable: (json['shared_available'] as num).toInt(),
      envelopeTotal: (json['envelope_total'] as num).toInt(),
      overspendTotal: (json['overspend_total'] as num).toInt(),
      categories: [
        for (final c in (json['categories'] as List))
          EnvelopeSummary.fromJson((c as Map).cast<String, dynamic>()),
      ],
      memberId: me?['member_id'] as String?,
      personalBalance: me == null ? null : (me['personal_balance'] as num).toInt(),
    );
  }

  final int sharedBalance;
  final int sharedAvailable;
  final int envelopeTotal;
  final int overspendTotal;
  final List<EnvelopeSummary> categories;

  /// 呼叫者自己（security invoker 下只算得到自己；未入帳本時為 null）。
  final String? memberId;
  final int? personalBalance;

  /// 該分類的信封列；當月無撥款也無預算支出的分類不在回傳裡 → 全 0。
  EnvelopeSummary envelopeOf(String categoryId) {
    for (final c in categories) {
      if (c.categoryId == categoryId) return c;
    }
    return EnvelopeSummary(categoryId: categoryId, allocated: 0, spent: 0, remaining: 0, over: 0);
  }
}
