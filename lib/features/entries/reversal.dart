/// 沖銷（Mike 裁示 2026-09-04，取代「修正筆」；v1.5／ADR-0009 沿用）：
/// 對一筆帳目產生一模一樣的反向紀錄——金額取負，**付款人（誰先付）與日期照抄**——
/// 讓補入剩餘、共同餘額、分類預算沿原路整筆回退；使用者再用複製的原資訊
/// 手動重新記一筆正確的。負數合法性沿用 DB 的 is_adjustment 通道（entries_amount_sign）。
///
/// v1.5 起每筆只記「誰先付」：反向筆只需要照抄 `payerId`
/// （非 null＝該成員先付、null＝共同錢包），三個數就會自己回退。
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

/// 組一筆反向紀錄。
Entry buildReversal(Entry original, {required String me}) {
  return Entry(
    id: '', // 新筆，id 交給 DB
    ledgerId: original.ledgerId,
    kind: original.kind,
    amount: -original.amount,
    categoryId: original.categoryId,
    occurredOn: original.occurredOn, // 同日反向：與原筆同一個月摘要桶互抵
    createdBy: me,
    note: '沖銷 #${reversalTag(original)}：${original.note}'.trim(),
    // 誰先付照抄原筆：原筆扣誰的補入剩餘，反向筆就補回誰的；
    // null（共同錢包）照樣照抄，共同餘額才會沿原路加回去。
    payerId: original.payerId,
    isAdjustment: true,
    // 細項是備註性質，不做反向（金額守恆在主筆）。
  );
}
