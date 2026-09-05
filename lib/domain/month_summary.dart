/// `month_summary` RPC 的回傳形狀（v1.5／ADR-0009）。
/// 畫面上的衍生數字（共同餘額／預算／已花／超支／每人補入剩餘）由 DB 依 Supabase 資料計算
/// （Mike 裁示 2026-09-03），客戶端只解析顯示；`InMemoryLedgerRepository` 用 balance_math
/// 算出同形狀供測試與 USE_MOCK。
///
/// v1.5 沒有 `me` 那組鍵（個人餘額／每月補入額／月淨變動隨額度制一起移除）：
/// 兩人都看得到彼此的補入與剩餘，所以是一份 `members` 清單，不是「只算自己」。
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

  /// 該分類該月的**全部**支出（不分誰付）。
  final int spent;
  final int remaining;
  final int over;
}

/// 一位成員在該月的補入狀態（`members[]` 的一列，依 `joined_at, id` 排序）。
class MemberMonthLine {
  const MemberMonthLine({
    required this.memberId,
    required this.displayName,
    required this.topup,
    required this.paid,
    required this.remaining,
  });

  factory MemberMonthLine.fromJson(Map<String, dynamic> json) => MemberMonthLine(
        memberId: json['member_id'] as String,
        displayName: json['display_name'] as String,
        topup: (json['topup'] as num).toInt(),
        paid: (json['paid'] as num).toInt(),
        remaining: (json['remaining'] as num).toInt(),
      );

  final String memberId;
  final String displayName;

  /// 該月補入合計。
  final int topup;

  /// 該月本人先付的支出合計。
  final int paid;

  /// 補入剩餘＝[topup] − [paid]，可為負（先付超過補入）。
  final int remaining;
}

class MonthSummary {
  const MonthSummary({
    required this.sharedBalance,
    required this.budgetTotal,
    required this.spentTotal,
    required this.overspendTotal,
    required this.categories,
    required this.members,
    required this.sharedPaid,
  });

  factory MonthSummary.fromJson(Map<String, dynamic> json) => MonthSummary(
        sharedBalance: (json['shared_balance'] as num).toInt(),
        budgetTotal: (json['budget_total'] as num).toInt(),
        spentTotal: (json['spent_total'] as num).toInt(),
        overspendTotal: (json['overspend_total'] as num).toInt(),
        categories: [
          for (final c in (json['categories'] as List))
            EnvelopeSummary.fromJson((c as Map).cast<String, dynamic>()),
        ],
        members: [
          for (final m in (json['members'] as List))
            MemberMonthLine.fromJson((m as Map).cast<String, dynamic>()),
        ],
        sharedPaid: (json['shared_paid'] as num).toInt(),
      );

  /// Σ共同收入 − Σ共同錢包支出（清帳、補入都不影響它）。
  final int sharedBalance;

  /// 該月的 Σ預算。
  final int budgetTotal;

  /// 該月的 Σ支出（不分誰付）。
  final int spentTotal;
  final int overspendTotal;
  final List<EnvelopeSummary> categories;

  /// 每位成員該月的補入、先付、剩餘（已清月照帳目算）。
  final List<MemberMonthLine> members;

  /// 該月共同錢包（`payer_id is null`）支出合計。
  final int sharedPaid;

  /// 該分類該月的預算列；該月既無預算也無支出的分類不在回傳裡 → 全 0。
  EnvelopeSummary envelopeOf(String categoryId) {
    for (final c in categories) {
      if (c.categoryId == categoryId) return c;
    }
    return EnvelopeSummary(categoryId: categoryId, allocated: 0, spent: 0, remaining: 0, over: 0);
  }

  /// 某位成員該月那一列；不在回傳裡（還沒加入）→ 全 0。
  MemberMonthLine memberLineOf(String memberId) {
    for (final m in members) {
      if (m.memberId == memberId) return m;
    }
    return MemberMonthLine(
        memberId: memberId, displayName: '', topup: 0, paid: 0, remaining: 0);
  }
}
