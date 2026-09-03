# ADR-0002 任意時間結算、多簽、已結帳鎖金額

日期 2026-09-02　狀態 accepted

## 決策
- 結算任意時間發起，涵蓋所有 open 的代墊共同支出，算淨額。
- 需簽者＝淨額非零成員減發起人；全簽完由 Postgres RPC（security definer）在同一交易落 settled。
- settling 期間涵蓋 entry 被改 → settlement void、entry 回 open。
- settled 的 entry 鎖金額／payer／split（trigger 擋），只允許改分類、備註、細項；金額錯誤以修正筆（可負）處理。
- 付款來源＝共同錢包（payer null）或 split common 不產生債務。

## 後果
不需自建後端；差額重算問題不存在；多簽原子性由 DB 保證。
