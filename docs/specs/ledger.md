# 共同記帳 app — Spec v1.2（2026-09-02；v1.1 增「UI 互動原則」、結帳表單簡化、圖表套件；v1.2 預算改信封制）

> 一切開發依本檔。改版需 Mike 點頭並記版次。決策依據見 `docs/adr/`。

## 目標

夫妻兩人（不限人數）共同記帳：記收支、分攤代墊、結算、看趨勢、管預算、購物清單。自用，設定極簡。
參照物：Shareroo（App Store id1475406336），取其分攤結算與預算，砍 AI、訂閱、背景。

## 範圍 / 非目標

- 做：帳目（含細項）、分攤與結算（多簽）、統計、預算（含 rollover）、購物清單與待辦（與預算整合）、多帳本、Apple 登入。
- 不做：AI 收據辨識、收據照片、訂閱、自訂背景、多幣別、通知推播（僅「有結算等你簽」一種，排階段五之後）。

## 技術

- 前端 Flutter 3.44（Web 先、iOS 後）；Riverpod、go_router、syncfusion_flutter_charts（v1.1 起取代 fl_chart）、Material 3 自訂主色＋深色模式。
- 資料 Supabase 雲端免費專案（dev / prod 各一），無自建後端；多簽與結算用 Postgres RPC（security definer）＋ trigger。
- 登入 Sign in with Apple（第一天即接）；Auth 走雲端 Supabase。
- 幣別台幣，金額整數元；分攤額 numeric(12,2)，結算淨額四捨五入整數。

## UI 互動原則（v1.1，Mike 裁示：一律照現代手機 app 慣例，不照網頁慣例）

- 選年月：點標題開年月彈窗（`lib/app/month_picker.dart` 的 `MonthTitle`／`showMonthPicker`），標題左右滑切月，兩側另有 ‹ › 箭頭快速切月。
- 表單與選項一律 bottom sheet，不用 dialog（刪除確認除外）。
- 圖表用 syncfusion_flutter_charts：固定高度、legend 一排可點切線別、軸標籤自動間距、trackball；資料空時圖區保留高度顯示提示。
- 點擊目標 ≥44px；列表項目支援滑動操作；輸入金額用數字鍵盤。
- 月份標題：左右箭頭快速切月＋點標題開年月彈窗（`MonthTitle`）。家庭／個人切換用共用 `ViewModeToggle`（滿版等寬、不換行）。
- 外觀：設定頁可切白天／夜晚／跟隨系統（`themeModeProvider`，SharedPreferences 持久化）。設定頁緊湊、一頁顯示。
- 統計趨勢預設顆粒度「月」。結算待簽核卡片小型化（一行摘要＋按鈕）。
- **資訊密度（Mike 裁示）**：每個畫面與彈窗只放主要資訊；說明文字最多一短行、只在錯誤時出現；不做卡片套卡片；選項列「標籤在左、chip 在右」單行；折疊區收起時只留一行摘要；彈窗高度以內容為準、緊湊直覺。
- 分攤「比例」可逐筆調整：預設帶入帳本 default_ratio，表單內每成員百分比可改（合計 100），存成該筆 splits（v1.2）。

## 領域模型

- **ledger**：帳本。`id, name, invite_code(6碼), default_ratio(jsonb member→%), opening_balance_shared(int), created_at`。多帳本可切換。
- **member**：帳本成員。`ledger_id, user_id, display_name, opening_balance_personal(int), joined_at`。以邀請碼加入，不限人數。
- **category**：`ledger_id, kind(expense|income), name, icon, sort, rollover(bool)`。app 內可增刪改。
- **entry**：一筆收入或支出。
  `ledger_id, kind(expense|income), scope(private|shared), amount(int), category_id, occurred_on(date), note, created_by,
   payer(member_id | null=共同錢包), split_method(equal|ratio|amount|common), settled_state(open|settling|settled), is_adjustment(bool)`
  - `scope=private`：只有 `created_by` 看得到（RLS），不參與分攤結算，payer 固定自己。
  - `kind=income` 且 `scope=shared`：依 `default_ratio` 均分成份額，不參與結算。
  - `split_method=common` 或 `payer=null`：共同錢包出，不產生債務。
- **entry_split**：每筆共同支出每成員一列。`entry_id, member_id, share(numeric 12,2)`。細項不分攤。
- **line_item**：細項。`entry_id, name, amount(int|null), sort`。加總可不等於主筆金額；用於模糊搜尋。
- **settlement**：`ledger_id, status(pending|settled|void), initiated_by, created_at, settled_at, nets(jsonb member→int)`。
- **settlement_entry**：`settlement_id, entry_id`。
- **settlement_approval**：`settlement_id, member_id, approved_at`。
- **budget**：`ledger_id, category_id, month(date, 該月 1 號), limit(int)`。改動只影響該月起（以最近一筆 ≤ month 的 limit 為基礎上限）。
- **list_item**：購物清單與待辦同表。`ledger_id, title, store(text|null), estimated(int|null), category_id(null=待辦), assignee(member_id|null), due_on, done_at, entry_id(勾選後產生的支出), sort`。

## 行為規格

### 帳目
- 底部 Tab：帳目、統計、預算、清單；設定在帳目頁右上齒輪。
- 帳目頁：月份切換、視角切換（家庭／個人）、依日分組列表、右下新增按鈕；頂部「待簽核／結算中」卡片有事才出現。
- 新增表單全螢幕：金額大字、分類格子、日期、備註、細項（可展開、每列名稱＋金額可空）、下方折疊區：範圍（共同／私人）、付款來源、分攤方式；預設值＝共同、共同錢包、common（ADR-0005）。
- 分攤方式：equal 均分；ratio 依帳本 default_ratio；amount 手填各成員金額且合計須等於主筆；common 無分攤。
- 修正筆：`is_adjustment=true`，金額可負，列表顯示「修正」標籤，統計正常計入。
- 已結帳（settled）的支出：金額、payer、split 鎖住（DB trigger 擋更新）；分類、備註、細項可改。

### 結算（ADR-0002）
- 發起：選帳本內所有 `open` 且 payer 非共同錢包的共同支出 → 算每人淨額（付出總額 − 分攤總額）→ 建 pending settlement，涵蓋 entry 轉 `settling`。
- 需要簽的人＝淨額非零的成員 − 發起人。全部簽完 → RPC 在同一交易改 entry 為 `settled`、settlement 為 `settled`。
- `settling` 期間涵蓋的 entry 任何改動 → trigger 把 settlement 標 `void`、entry 回 `open`。
- Realtime 訂閱 settlements / entries，app 開著即時更新。

### 統計
- 視角：家庭（僅 shared）／個人（private ＋ 自己在 shared 的份額 ＋ 自己的收入）。
- 圓餅：依分類／依成員，期間可選月或週。
- 趨勢圖：顆粒度日／週（週一起）／月／年，四條線：花費（桶合計）、預算（桶內有效上限合計）、超支（max(0, 花費−預算)）、餘額（累計：期初＋收入−支出）。
- 月摘要：收入、支出、損益、累計餘額（共同一條、個人各一條）。

### 預算（v1.2 信封制，取代 v1 的「每分類上限」；Mike 2026-09-02 裁示）
- **餘額＝可用餘額＋預算總額**。收入／支出決定餘額；預算是從可用餘額「撥」進分類信封的錢，撥款當下預扣可用餘額。
- 撥款（allocation）：手動對某分類撥入金額（可負＝退回可用餘額）；可設每月自動撥款（月初自動撥固定額）。撥款跟著分類走，一分類一信封。
- 支出資金來源（`funding`）：預設 `budget`（扣該分類信封，用完繼續扣＝信封為負＝超支，不擋只標紅）；要刻意從可用餘額出才手動選 `balance`。花費＝預算支出＋餘額支出。
- 每月 1 號前要設定當月預算：進入新月份若該月無撥款，預算頁頂部提示「設定本月預算」，可一鍵套用上月撥款或自動撥款設定。
- **清單只是購物車**：未結帳前不影響可用餘額與任何信封（不預留、不顯示預留段）；勾選結帳產生支出那一刻才依 funding 扣（Mike 2026-09-02 確認）。
- rollover 改義為「月底信封餘額是否留到下月」：開＝留（含負數），關＝月底自動退回可用餘額（記一筆反向撥款）。
- 趨勢圖的「預算」與「餘額」兩線是**水位**：預算線＝各分類信封剩餘合計（撥款−預算支出）隨時間的餘量；餘額線＝可用餘額（期初＋收入−撥款−餘額支出）餘量；「花費」線＝預算支出＋餘額支出；「超支」＝信封負值合計。
- 領域模型新增：`budget_allocation(ledger_id, category_id, amount int, occurred_on date, kind manual|auto|rollback, note)`；`entries.funding enum('balance','budget') default 'balance'`；`budgets` 表改為每分類的自動撥款設定 `(category_id, monthly_amount, rollover)`。
- 落地：波 2 與 DB 一起實作（migration 0022 起）；波 1 的預算頁維持 v1 版面不再精修。

### 清單
- 購物項目：名稱、店家分組、預估金額、分類、負責人。待辦：無金額無分類，可指派、到期日（app 內標示，不推播）。
- 勾選：單項→sheet 只有一個金額欄（預填預估）；多項→每項實際金額欄、總計唯讀自動加總。產生 shared expense（分類、名稱帶入，項目成細項，預設 payer/split 同新增表單預設）；主筆金額＝加總，不可手改（v1.1）。

### 搜尋
- 比對 line_item.name、entry.note、list_item.title（ILIKE／pg_trgm）。結果以細項為單位：品項、金額、日期、分類、備註，點開主筆；同名品項附價格折線。

### 帳本與成員
- 第一次登入自動建帳本；設定頁顯示邀請碼、可輸入邀請碼加入他人帳本、可建新帳本與切換。
- 設定頁內容：帳本切換、邀請碼、成員、default_ratio、期初餘額（共同一個、個人各一個）、分類管理（子頁 `/settings/categories`）、外觀。預算已是獨立 Tab，不另設入口。

## 驗收總表

| 模組 | 證據 |
| --- | --- |
| schema/RLS/RPC | `supabase db reset` 全綠；pgTAP 或 SQL 腳本驗 RLS（私人不可見）、結算多簽、settled 鎖 |
| 前端 | `flutter analyze` 無錯；`flutter test` 全綠；Mike 地端手測（Flutter Web hot reload） |
| 結算 | 兩帳號 e2e：A 代墊、B 簽、狀態 settled、entry 鎖住 |
| 統計 | 已知資料集算出的四條線數值與 SQL 手算一致 |

## 已決策清單

ADR-0001 資料模型（細項附註、分攤掛主筆）；ADR-0002 結算多簽與鎖定；ADR-0003 私人／共同範圍；ADR-0004 rollover 與餘額；ADR-0005 平台與預設值。
