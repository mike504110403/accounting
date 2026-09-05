# WIP — accounting 記帳 app（/mega：帳務規則 v1.4）

更新：2026-09-05 凌晨（/wip 收斂；v1.4 已合 dev 並推 origin、雲端 dev／prod 已 migration、TestFlight build 7 已上傳，等 Mike 手測）

## 任務背景與目標

夫妻共同記帳 Flutter Web/iOS app（Supabase 後端）。spec `docs/specs/ledger.md`（**v1.4**，帳務規則見「餘額與預算」「清帳」節）、決策 `docs/adr/0001–0008`、DB 契約 `docs/specs/db-contract.md`。
v1.4（ADR-0008，Mike 2026-09-04 十題裁示）：個人餘額改額度制（每月補入額）、預算改影子紀錄（每分類每月設定一次、不可改）、drop 資金來源、新增月清帳（三方對帳明細、個人餘額歸零、鎖定該月及更早月份）、共同餘額只由手動收支推動。

**設計原則（Mike 2026-09-05）**：只有 Mike 與老婆兩人用、純客製化——裁示題一律照兩人互信判，不做多租戶硬化，只守「外人進不來」。
**環境政策（Mike 2026-09-05）**：**不再起地端 DB**；地端開發連 Supabase dev（app 預設），TestFlight 連 prod（`tool/build_ios.sh` 注入）。

## 已完成

- 波 1（2026-09-03 合 dev 422fe71）：四頁假資料＋DB 23 支 migration。
- 波 2（2026-09-04 合 dev，24 顆）：接 Supabase、信封制 v1.3、沖銷重記、iOS TestFlight build 1～6。
- **v1.4（2026-09-05 合 dev 2c6a020 一顆；dev 推 origin 至 d9d7a25）**：
  - DB：migration `20260904000200_rules_v14.sql` 合一支（`members.monthly_topup`、撥款每月一筆 unique＋`amount>0`＋收回 UPDATE/DELETE、drop `entries.funding`、`month_closes` 表、`close_month`／`month_close_preview` RPC、鎖月 trigger ≤ 最後清帳月、`entry_member_effects` security_invoker view 單一錢公式、`month_summary` 重寫輸出 bigint、`archive.budget_allocation_v13` 快照）。SQL 測試全綠、db／security／code 三 reviewer 兩輪＋MINOR 確認全過。
  - 前端：去資金來源（表單／結帳／沖銷）；domain／data 對齊（額度制 `personalBalance`、最大餘數法 `integerShares`、`isMonthClosed` ≤ max、清帳 repository 三方法、`MonthClose` 模型、errors 八條映射）；預算頁影子 UI（四格、一次設定、複製上月 spec 口徑）；設定頁餘額設定拆兩列＋清帳頁（前端可清條件三原因、預覽、二次確認、列表）＋鎖月 UI；統計標籤依視角、已清月讀快照、前史月 0、非月顆粒度斷線、未來月投影。整套 421 綠、INTEGRATION 45 綠、每片 code-reviewer 過。
  - 部署：雲端 dev 撥款 18→7 合併、prod 2→2；三表 pg_dump 備份在 session scratchpad（不進 git）。iOS **0.1.0 (7)** stamp ios-0905-0139 altool 上傳成功（Delivery 2e485f05）。

## 需求／波次看板

| 需求/波次                                                     | 階段                    | feature 分支              | 切自 dev | 依賴 | review 現況 |
| ------------------------------------------------------------- | ----------------------- | ------------------------- | -------- | ---- | ----------- |
| v1.4 帳務規則（波 1 DB＋表單、波 2 domain／預算／清帳／統計） | 已合併（2c6a020）、已推 | feature/rules-v14（已刪） | 5064f8f  | —    | 全過        |

## 收斂時進行中的工人

無。worktree 只剩主 checkout（dev fc8770f）；無 `wt/`／`feature/` 分支。

## 決策

- 已解：ADR-0001～0008（0008＝v1.4；spec 內另有三處精確化：份額取整最大餘數法、無分攤列拆帳不擋清帳、鎖定含更早月份＋二次確認）。
- 已解（Mike 09-05）：prod 不關 signup（dev 也不動）；review 三題依兩人客製原則收掉（payer 可指他人不限、時區不處理、可清條件三份實作留著）。
- 尚未明朗：無。

## Mike 手測回報（2026-09-05 下午，build 7）

1. **已做（feature/member-name，/solo）**：首登／加入帳本要填名稱、設定頁「我的名稱」隨時改、切換 sheet 加入／新增帶名。根因：Apple 登入 email-only scope → RPC 退到隱藏信箱前綴代號（prod 實查 `4yrcfzrc99`／`kv4nrp6vy2`）。
2. **待開（v1.5 帳務規則，需 ADR-0009 ＋ DB migration → /feature 或 /mega）**：
   - 共同期初餘額拿掉；共同餘額只由手動「新增」收支推動。
   - 每月補入額改語意「個人預留給共同花費使用的款項」，整合進獨立的「個人餘額」頁（不放帳目內），只能透過「補入個人餘額」新增。
   - 帳目列表與行為不再分共同／個人，同一頁；支出只分「共同餘額付」或「誰代墊」。
   - 預算內新增一欄「個人補入剩餘」：支出誰出的扣誰的補入剩餘、共同出的直接扣共同餘額。
   - 預算預先匯播：任何支出都要扣對應分類的預算；預算以月為單位；後續看每月趨勢圖。
   - **頁面結構（Mike 09-05）只剩四頁**：(1) 帳目——不分家庭／個人；(2) 統計——圖一起統計（支出就是支出，只分誰先付）；(3) 預算——多加「個人補入」區塊，個人餘額也放這頁；(4) 清單——維持，結帳行為改新制。
   - **總綱（Mike 09-05）**：概念上只有一種帳目＝家庭支出，只區分「買的東西類型（分類）」與「誰先付錢（共同餘額或某人代墊）」。個人補入概念上也是預算＝個人先預留出來付共同支出的錢；原本的分類預算是影子紀錄所有支出、用來審視家庭開銷。每月清帳＝使用者依明細把真實的錢互相清償，清償後回到設定狀態（補入額歸位）。
   - 影響面待 scout-trace：`entry_member_effects` 錢公式、`month_summary`、`close_month` 快照、統計個人視角、預算影子紀錄（ADR-0006／0008 多處要改寫）。**先 /office-hours 對齊語意再開工。**

## 待 Mike 裁示

- SQL 測試 `supabase/tests/run.sh` 需地端 DB：建議**只在有新 migration 時臨時起一次棧跑完就關**（選這個＝migration 仍有回歸網、平時不起棧；不選＝SQL 測試等於停用，DB 改動只剩雲端 dev smoke）。
- 統計第一列 6 顆按鈕 390px 偏擠：看實機，不順眼一行改回兩列（可逆 UI）。

## 下一步

1. **Mike TestFlight build 7 手測**（prod）：清單 `.claude/handtest-v14.md`（21 條，地端版寫法；prod 上帳號換真帳號）；prod 版重點——設定頁餘額設定兩列、預算頁四格與未設定分類列、清帳流程（先結算簽核 → 清帳 → 二次確認 → 兩帳號同步）、統計已清月／未來月語意、週顆粒度已清月斷線的 trackball。問題走 /bug。
2. dev 有兩顆未推 docs commit（fc8770f、3f20e98＝本檔），下次 /ship 順帶。
3. 待辦池（既有）：帳號刪除＋刪帳本 RPC（上架硬需求）、隱私政策入口、token 進 Keychain、iOS home indicator padding（5 個 sheet）、螢幕閱讀器導覽卡步、settings_page 拆檔（已 869 行）、`isSettleable` 補「有分攤列」判準、可清條件三份實作搬 domain、db-contract Migration 一覽補兩列既有 migration。
4. 工程死亡點：Mike 手測過即可刪本檔（歷史在 ADR 與 git log）。

## 環境備忘

- 雲端 Supabase：dev ref wxqbxsagfvtxnvaloklr（app 預設）、prod ref 在 `~/mike/supabase/prod.env`；DB 密碼 dev `~/.config/accounting/supabase.env`、prod 同上檔。pooler 連法 `postgresql://postgres.<ref>:<pw>@aws-0-ap-northeast-1.pooler.supabase.com:5432/postgres`（`supabase/.temp/pooler-url` 那條 pg_dump 會卡，用這個）。主 checkout `supabase/.temp` link 雲端 dev，`db push` 直打 dev；prod 用 `db push --db-url`。
- 既有雷：`~/.claude/ledgers/accounting.md`（v1.4 review 順路發現已登記：時區、payer 可指他人、可清條件三份、預算頁已清月可開 sheet、run.sh 重試接不到 reset 失敗、psql dollar-quote 不代換等）。
- 看畫面：`tool/dev.sh 8787`（連雲端 dev；Mike 舊 session 可能仍有一支在跑）；iOS：`tool/build_ios.sh --build-number N` → `xcrun altool --upload-app --apiKey/--apiIssuer`（key 已放 `~/.appstoreconnect/private_keys/`，env 在 `~/mike/asc/asc.env`）。下一顆 build 號 8。
- 環境 PATH：`flutter` 在 `/opt/homebrew/bin`、`docker` 在 `/usr/local/bin`、`psql`／`pg_dump` 在 `/opt/homebrew/opt/libpq/bin`；macOS 無 `timeout`，用 `PGCONNECT_TIMEOUT`。
