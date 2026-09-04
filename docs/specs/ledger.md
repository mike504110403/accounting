# 共同記帳 app — Spec v1.3（2026-09-03；v1.1 增「UI 互動原則」、結帳表單簡化、圖表套件；v1.2 預算改信封制；v1.3 帳務規則重整：共同預算單套、超支重算、個人／共同餘額連動）

> 一切開發依本檔。改版需 Mike 點頭並記版次。決策依據見 `docs/adr/`。

## 目標

夫妻兩人（不限人數）共同記帳：記收支、分攤代墊、結算、看趨勢、管預算、購物清單。自用，設定極簡。
參照物：Shareroo（App Store id1475406336），取其分攤結算與預算，砍 AI、訂閱、背景。

## 範圍 / 非目標

- 做：帳目（含細項）、分攤與結算（多簽）、統計、預算（共同一套、信封制）、購物清單與待辦（與預算整合）、多帳本、Apple 登入。
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
- **category**：`ledger_id, kind(expense|income), name, icon, sort`。app 內可增刪改。（v1.3 拿掉 rollover。）
- **entry**：一筆收入或支出。
  `ledger_id, kind(expense|income), scope(private|shared), amount(int), category_id, occurred_on(date), note, created_by,
   payer(member_id | null=共同錢包), split_method(equal|ratio|amount|common), settled_state(open|settling|settled), is_adjustment(bool),
   funding(balance|budget)`
  - `funding`：資金來源（v1.3）。只有 `payer=null`（共同錢包）且 `kind=expense`、`scope=shared` 時可為 `budget`；其餘一律 `balance`（DB check）。
  - `scope=private`：只有 `created_by` 看得到（RLS），不參與分攤結算，payer 固定自己。
  - `kind=income` 且 `scope=shared`：依 `default_ratio` 均分成份額，不參與結算。
  - `split_method=common` 或 `payer=null`：共同錢包出，不產生債務。
- **entry_split**：每筆共同支出每成員一列。`entry_id, member_id, share(numeric 12,2)`。細項不分攤。
- **line_item**：細項。`entry_id, name, amount(int|null), sort`。加總可不等於主筆金額；用於模糊搜尋。
- **settlement**：`ledger_id, status(pending|settled|void), initiated_by, created_at, settled_at, nets(jsonb member→int)`。
- **settlement_entry**：`settlement_id, entry_id`。
- **settlement_approval**：`settlement_id, member_id, approved_at`。
- **budget_allocation**（v1.3，取代 budget 表）：`ledger_id, category_id, amount(int, 可負), occurred_on(date), note, created_by`。一列＝一次手動撥款／退回；信封只看當月列，不跨月。
- **list_item**：購物清單與待辦同表。`ledger_id, title, store(text|null), estimated(int|null), category_id(null=待辦), assignee(member_id|null), due_on, done_at, entry_id(勾選後產生的支出), sort`。

## 行為規格

### 帳目
- 底部 Tab：帳目、統計、預算、清單；設定在帳目頁右上齒輪。
- 帳目頁：月份切換、視角切換（家庭／個人）、依日分組列表、右下新增按鈕；頂部「待簽核／結算中」卡片有事才出現。
- 新增表單全螢幕：金額大字、分類格子、日期、備註、細項（可展開、每列名稱＋金額可空）、下方折疊區：範圍（共同／私人）、付款來源、分攤方式、資金來源；預設值＝共同、共同錢包、common（ADR-0005）。
- 資金來源（v1.3）：付款來源＝共同錢包時顯示「預算／餘額」；該分類當月有撥款預設「預算」，否則預設「餘額」。付款來源切成成員（代墊）時欄位隱藏、強制「餘額」。
- 分攤方式：equal 均分；ratio 依帳本 default_ratio；amount 手填各成員金額且合計須等於主筆；common 無分攤。
- 沖銷（2026-09-04 取代修正筆）：settled 筆可一鍵沖銷——自動產生 `is_adjustment=true`、金額與份額取負的反向紀錄（付款來源／資金／日期照抄原筆），拆帳、預算、餘額沿原路整筆回退，列表顯示「沖銷」標籤、統計正常計入；接著以原資訊帶入新增流程重記。使用者不再手動輸入負數。
- 已結帳（settled）的支出：金額、payer、split 鎖住（DB trigger 擋更新）；分類、備註、細項可改。

### 結算（ADR-0002）
- 發起：選帳本內所有 `open` 且 payer 非共同錢包的共同支出 → 算每人淨額（付出總額 − 分攤總額）→ 建 pending settlement，涵蓋 entry 轉 `settling`。
- 需要簽的人＝淨額非零的成員 − 發起人。全部簽完 → RPC 在同一交易改 entry 為 `settled`、settlement 為 `settled`。
- 單筆帳目不需簽核，記了即生效；只有結算要簽（v1.3 確認）。
- `settling` 期間涵蓋的 entry 任何改動 → trigger 把 settlement 標 `void`、entry 回 `open`。
- Realtime 訂閱 settlements / entries，app 開著即時更新。

### 統計
- 視角：家庭（僅 shared）／個人（private ＋ 自己在 shared 的份額 ＋ 自己的收入）。
- 圓餅：依分類／依成員，期間可選月或週。
- 趨勢圖（v1.3）：顆粒度日／週（週一起）／月／年。家庭視圖三條線：花費（桶內共同支出合計，不分付款人與資金來源）、可用餘額（水位：桶末的共同可用餘額）、超支（桶末的當月超支合計）；個人視圖兩條線：花費、個人可用餘額。預算線拿掉。
- 月摘要：收入、支出、損益、可用餘額（共同一條、個人各一條）。

### 餘額與預算（v1.3 帳務規則，Mike 2026-09-03 裁示；ADR-0007）
- **四個概念**：收入、支出、餘額、預算。餘額＝錢：共同一個、每位成員個人一個，皆可為負。
- **預算只有共同一套**，每分類一個信封。撥款純手動、隨時加減（可負＝退回）；撥款當下從共同可用餘額預扣。**信封只看當月**：月底剩餘一律退回，不跨月、不自動撥款。
- **共同餘額＝共同可用餘額＋當月信封剩餘合計**；信封剩餘＝max(0, 當月撥款 − 當月預算支出)。
- **資金來源**：只有付款人＝共同錢包的共同支出可選「預算」；代墊（付款人＝成員）與私人支出一律走餘額，不進預算。
- **超支**＝當月「該分類預算支出 − 當月撥款」的正值部分，**隨時重算**（補撥即回補）；超支額從共同可用餘額扣。花費＝預算支出＋餘額支出。
- **連動**：
  - 共同錢包付 → 共同餘額即扣（依資金來源扣信封或可用餘額）。
  - 代墊 → 記帳當下只扣付款人自己的個人餘額（全額）；其他人的個人餘額不動。
  - 結算全簽完那一刻：每位其他成員個人餘額扣自己的份額、代墊者個人餘額拿回（金額＋自己的份額）。結算後每人個人餘額恰等於自己實際負擔。
  - 私人帳目只動本人個人餘額；共同收入進共同餘額、個人收入進個人餘額。
- **清單只是購物車**：未結帳前不影響任何餘額與信封；勾選結帳產生支出那一刻才依資金來源扣。
- 預算頁：頂部可用餘額＋信封總額；每分類一列：撥款、已花、剩餘／超支；點列開 sheet 撥款或退回。進入新月份若該月無撥款，頂部提示「設定本月預算」，可一鍵複製上月撥款。

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
| 統計 | 已知資料集算出的三條線（花費、可用餘額、超支）與 SQL 手算一致 |
| 餘額連動 | 兩帳號 e2e：代墊 1,000 均分 → 付款人個人 −1,000；簽完 → 付款人 −500、對方 −500、共同不變 |

## 已決策清單

ADR-0001 資料模型（細項附註、分攤掛主筆）；ADR-0002 結算多簽與鎖定；ADR-0003 私人／共同範圍；ADR-0004 rollover 與餘額（已被 0006、0007 取代）；ADR-0005 平台與預設值；ADR-0006 信封制（部分被 0007 取代）；ADR-0007 帳務規則 v1.3。
