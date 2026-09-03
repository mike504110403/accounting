# ADR-0005 雲端 Supabase 優先、Apple 登入第一天接、新增預設值

日期 2026-09-02　狀態 accepted

## 決策
- 不跑地端 Supabase：dev/prod 各一個雲端免費專案，migration 在 repo 以 CLI push。理由：Apple Return URL 需公開 HTTPS。
- Sign in with Apple 從第一天接（Mike 已有開發者帳號）。
- 幣別台幣整數；分攤兩位小數；結算四捨五入。
- 新增共同支出預設：scope shared、payer 共同錢包、split common；個人代墊時手動切。default_ratio 存帳本。
- 分類與預算在 app 內可編輯；多帳本可切換，以邀請碼加入。
- 不做收據照片、AI、推播（僅結算待簽一種，延後）。

## 補充（2026-09-02，db review 後）
- 結算淨額進位用最大餘數法：全員 floor，差額依小數部分由大到小各補 1，小數相同時依 member_id 順序，Σnets 恆為 0（兩人帳本各 .5 時餘 1 元歸 member_id 較小者）。
- 分攤份額 Σshare 必須等於主筆金額（common／private 除外），由 DB deferred constraint 保證；前端均分／比例的餘數補在第一位成員。
- 狀態機類資料（settlements、settlement_entries、settlement_approvals、entries.settled_state）前端只讀，寫入只走 RPC；entries 對前端採欄位級授權。
