/// `month_summary` RPC 的回傳形狀（migration 20260904000200，v1.4／ADR-0008）。
/// 畫面上的衍生數字（共同餘額／預算／已花／超支／個人餘額）由 DB 依 Supabase 資料計算
/// （Mike 裁示 2026-09-03），客戶端只解析顯示；`InMemoryLedgerRepository` 用 balance_math
/// 算出同形狀供測試與 USE_MOCK。
///
/// v1.3 的 `shared_available`／`envelope_total` 兩鍵已隨信封制一起移除。
library;

/// 一個分類在該月的預算狀態（`categories[]` 的一列）。
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

  /// 該分類該月的預算（0 或那一筆的金額）。
  final int allocated;

  /// 該分類該月的**所有**共同支出（不分 payer，代墊也算）。
  final int spent;
  final int remaining;
  final int over;
}

class MonthSummary {
  const MonthSummary({
    required this.sharedBalance,
    required this.budgetTotal,
    required this.spentTotal,
    required this.overspendTotal,
    required this.categories,
    this.memberId,
    this.personalBalance,
    this.monthlyTopup,
    this.monthNet,
  });

  factory MonthSummary.fromJson(Map<String, dynamic> json) {
    final me = json['me'] as Map<String, dynamic>?;
    return MonthSummary(
      sharedBalance: (json['shared_balance'] as num).toInt(),
      budgetTotal: (json['budget_total'] as num).toInt(),
      spentTotal: (json['spent_total'] as num).toInt(),
      overspendTotal: (json['overspend_total'] as num).toInt(),
      categories: [
        for (final c in (json['categories'] as List))
          EnvelopeSummary.fromJson((c as Map).cast<String, dynamic>()),
      ],
      memberId: me?['member_id'] as String?,
      personalBalance: me == null ? null : (me['personal_balance'] as num).toInt(),
      monthlyTopup: me == null ? null : (me['monthly_topup'] as num).toInt(),
      monthNet: me == null ? null : (me['month_net'] as num).toInt(),
    );
  }

  /// 共同期初 ＋ Σ共同收入 − Σ共同錢包支出（清帳不影響它）。
  final int sharedBalance;

  /// 該月的 Σ預算。
  final int budgetTotal;

  /// 該月的 Σ共同支出（不分 payer）。
  final int spentTotal;
  final int overspendTotal;
  final List<EnvelopeSummary> categories;

  /// 呼叫者自己（security invoker 下只算得到自己；未入帳本時為 null）。
  final String? memberId;
  final int? personalBalance;
  final int? monthlyTopup;

  /// 呼叫者在該月的淨變動（不管那個月清了沒）。
  final int? monthNet;

  /// 該分類該月的預算列；該月既無預算也無共同支出的分類不在回傳裡 → 全 0。
  EnvelopeSummary envelopeOf(String categoryId) {
    for (final c in categories) {
      if (c.categoryId == categoryId) return c;
    }
    return EnvelopeSummary(categoryId: categoryId, allocated: 0, spent: 0, remaining: 0, over: 0);
  }
}
