# ADR-0003 收入與支出皆分私人／共同

日期 2026-09-02　狀態 accepted

## 決策
- 每筆 entry 有 scope：private 僅本人可見（RLS）、shared 全成員可見。
- 私人不參與分攤結算，payer 固定本人。
- 共同收入依帳本 default_ratio 分份額，不參與結算。
- 統計兩視角：家庭（僅 shared）、個人（private ＋ 我在 shared 的份額）。餘額也分共同與個人，各有期初餘額。

## 後果
RLS 多一條規則；統計多一視角；私人消費不必另找 app。
