/// 沖銷（Mike 裁示 2026-09-04，取代「修正筆」）：對已結帳的帳目產生一模一樣的
/// 反向紀錄——金額、分攤份額全取負，付款來源／資金來源／日期照抄——
/// 讓拆帳、預算（信封）、共同／個人餘額沿原路整筆回退；使用者再用複製的原資訊
/// 手動重新記一筆正確的。負數合法性沿用 DB 的 is_adjustment 通道（entries_amount_sign）。
library;

import '../../domain/models.dart';

/// 沖銷備註裡引用原筆的短代碼（同時是「已沖銷過」的判定錨點）。
String reversalTag(Entry original) =>
    original.id.length >= 8 ? original.id.substring(0, 8) : original.id;

/// 這筆是否已有對應的沖銷紀錄。
bool hasReversal(Iterable<Entry> all, Entry original) {
  final tag = '#${reversalTag(original)}';
  return all.any((e) => e.isAdjustment && e.note.contains(tag));
}

/// 組一筆反向紀錄。呼叫端限 settled 筆（未鎖的直接編輯即可）。
Entry buildReversal(Entry original, {required String me}) {
  return Entry(
    id: '', // 新筆，id 交給 DB
    ledgerId: original.ledgerId,
    kind: original.kind,
    scope: original.scope,
    amount: -original.amount,
    categoryId: original.categoryId,
    occurredOn: original.occurredOn, // 同日反向：當月預算／月摘要在同一桶互抵
    createdBy: me,
    note: '沖銷 #${reversalTag(original)}：${original.note}'.trim(),
    // 私人筆的 payer 恆等於 createdBy（DB check）；共同筆照抄原付款來源。
    payerId: original.scope == EntryScope.private ? me : original.payerId,
    splitMethod: original.splitMethod,
    isAdjustment: true,
    funding: original.funding,
    splits: [
      for (final s in original.splits)
        EntrySplit(entryId: '', memberId: s.memberId, share: -s.share),
    ],
    // 細項是備註性質，不做反向（金額守恆在主筆與分攤）。
  );
}
