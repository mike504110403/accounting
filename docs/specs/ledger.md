# 共同記帳 app — Spec v1.4（2026-09-04；v1.1 增「UI 互動原則」、結帳表單簡化、圖表套件；v1.2 預算改信封制；v1.3 帳務規則重整：共同預算單套、超支重算、個人／共同餘額連動；v1.4 每月補入額、預算改影子紀錄、月清帳——ADR-0008）

> 一切開發依本檔。改版需 Mike 點頭並記版次。決策依據見 `docs/adr/`。

## 目標

夫妻兩人（不限人數）共同記帳：記收支、分攤代墊、結算、看趨勢、管預算、購物清單。自用，設定極簡。
參照物：Shareroo（App Store id1475406336），取其分攤結算與預算，砍 AI、訂閱、背景。

## 範圍 / 非目標

- 做：帳目（含細項）、分攤與結算（多簽）、統計、預算（共同一套、影子紀錄）、月清帳（三方對帳明細＋清帳列表）、購物清單（與預算整合）、多帳本、Apple 登入。
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
- **member**：帳本成員。`ledger_id, user_id, display_name, monthly_topup(int, 每月補入額), opening_balance_personal(int, v1.4 起廢用、恆不入公式), joined_at`。以邀請碼加入，不限人數；`monthly_topup` 只能改自己的。
- **category**：`ledger_id, kind(expense|income), name, icon, sort`。app 內可增刪改。（v1.3 拿掉 rollover。）
- **entry**：一筆收入或支出。
  `ledger_id, kind(expense|income), scope(private|shared), amount(int), category_id, occurred_on(date), note, created_by,
   payer(member_id | null=共同錢包), split_method(equal|ratio|amount|common), settled_state(open|settling|settled), is_adjustment(bool)`
  - v1.4 起 **沒有 `funding`**（資金來源欄位與 enum 已 drop）：所有支出都是「餘額支出」，預算只是影子紀錄。
  - `scope=private`：只有 `created_by` 看得到（RLS），不參與分攤結算，payer 固定自己。
  - `kind=income` 且 `scope=shared`：依 `default_ratio` 均分成份額，不參與結算。
  - `split_method=common` 或 `payer=null`：共同錢包出，不產生債務。
- **entry_split**：每筆共同支出每成員一列。`entry_id, member_id, share(numeric 12,2)`。細項不分攤。
- **line_item**：細項。`entry_id, name, amount(int|null), sort`。加總可不等於主筆金額；用於模糊搜尋。
- **settlement**：`ledger_id, status(pending|settled|void), initiated_by, created_at, settled_at, nets(jsonb member→int)`。
- **settlement_entry**：`settlement_id, entry_id`。
- **settlement_approval**：`settlement_id, member_id, approved_at`。
- **budget_allocation**（v1.4 語意＝「設定當月預算」）：`ledger_id, category_id, amount(int, > 0), occurred_on(date), month(date, 由 occurred_on 推導的月初, generated), note, created_by`。**每分類每月至多一列**（unique `(ledger_id, category_id, month)`），建立後**不可改、不可刪、不可退回**（前端無 UPDATE／DELETE 授權）；不跨月。
- **month_close**（v1.4 清帳紀錄）：`ledger_id, month(date 月初), closed_by(member_id), closed_at, details(jsonb)`。`details` ＝ `{members: [{member_id, display_name, topup, net, ending}], shared_delta}`：每位成員該月補入額、淨變動、月末餘額（＝topup＋net）；`shared_delta` 為該月共同餘額變動，僅供對照。unique `(ledger_id, month)`；前端只讀，只能經 RPC `close_month` 寫入。
- **list_item**：購物清單與待辦同表。`ledger_id, title, store(text|null), estimated(int|null), category_id(null=待辦), assignee(member_id|null), due_on, done_at, entry_id(勾選後產生的支出), sort`。

## 行為規格

### 帳目
- 底部 Tab：帳目、統計、預算、清單；設定在帳目頁右上齒輪。
- 帳目頁：月份切換、視角切換（家庭／個人）、依日分組列表、右下新增按鈕；頂部「待簽核／結算中」卡片有事才出現。
- 新增表單全螢幕：金額大字、分類格子、日期、備註、細項（可展開、每列名稱＋金額可空）、下方折疊區：範圍（共同／私人）、付款來源、分攤方式；預設值＝共同、共同錢包、common（ADR-0005）。v1.4 起**沒有「資金來源」列**。
- 分攤方式：equal 均分；ratio 依帳本 default_ratio；amount 手填各成員金額且合計須等於主筆；common 無分攤。
- 沖銷（2026-09-04 取代修正筆；同日擴為**所有編輯的實作**）：點「編輯」（左滑或明細鉛筆）＝沖銷重記——自動產生 `is_adjustment=true`、金額與份額取負的反向紀錄（付款來源／日期照抄原筆），拆帳、預算、餘額沿原路整筆回退，列表顯示「沖銷」標籤、統計正常計入；接著以原資訊帶入新增流程重記成新筆；列表因此保有「原筆(標已沖銷、刪除線)＋反向筆＋新筆」完整軌跡。就地編輯已移除；結算中與沖銷紀錄本身不可編輯；同筆僅可沖一次。使用者不再手動輸入負數。
- 已結帳（settled）的支出：金額、payer、split 鎖住（DB trigger 擋更新）；分類、備註、細項可改。
- **已清帳月份**（v1.4）：`occurred_on` 落在最後清帳月（含）以前的帳目一律不可新增、修改、沖銷、刪除（含分攤與細項；DB trigger `month closed`）；前端：表單日期選到已清帳月份顯示「該月已清帳」並鎖住下一步；列表左滑與明細對已清帳月份的帳目直接不提供編輯／刪除入口（與沖銷筆同型，不另提示）。

### 結算（ADR-0002）
- 發起：選帳本內所有 `open` 且 payer 非共同錢包的共同支出 → 算每人淨額（付出總額 − 分攤總額）→ 建 pending settlement，涵蓋 entry 轉 `settling`。
- 需要簽的人＝淨額非零的成員 − 發起人。全部簽完 → RPC 在同一交易改 entry 為 `settled`、settlement 為 `settled`。
- 單筆帳目不需簽核，記了即生效；只有結算要簽（v1.3 確認）。
- `settling` 期間涵蓋的 entry 任何改動 → trigger 把 settlement 標 `void`、entry 回 `open`。
- Realtime 訂閱 settlements / entries，app 開著即時更新。

### 統計
- 視角（2026-09-04 修訂）：**帳目列表**徹底分開——家庭＝僅 shared、個人＝僅自己的 private（單人帳本兩分頁才有區別）；「自己在 shared 的份額」只用於**統計頁**的個人視角（月摘要／圓餅／趨勢，view_math）。
- 圓餅：依分類／依成員，期間可選月或週。
- 趨勢圖（v1.4）：顆粒度日／週（週一起）／月／年。家庭視圖三條線：花費（桶內共同支出合計，不分付款人）、共同餘額（水位：桶末的共同餘額，不扣預算）、超支（桶末的當月超支合計，影子）；個人視圖兩條線：花費、個人餘額（桶末，v1.4 公式）。
- 月摘要：收入、支出、損益、餘額（標籤依視角：家庭「共同餘額」、個人「個人餘額」，與趨勢線同字；已清帳月的個人餘額讀清帳快照本人的月末餘額、帳本開始前的月份顯示 0、快照找不到本人顯示「—」；未來月的個人餘額為不含未來補入額的投影並加小字註明）。

### 餘額與預算（v1.4 帳務規則，Mike 2026-09-04 裁示；ADR-0008）
- **四個概念**：收入、支出、餘額、預算。餘額＝錢：共同一個、每位成員個人一個，皆可為負。預算是**影子紀錄**，不是錢。
- **共同餘額**＝共同期初 ＋ Σ共同收入 − Σ共同錢包支出（`payer=null`）。**只有手動記的共同收入與共同錢包支出會動它**；撥款、代墊、結算、清帳一律不動。共同可用餘額＝共同餘額（不再預扣信封）。
- **個人餘額**（額度制）：每位成員設定「每月補入額」`monthly_topup`，從加入帳本那個月起每月加一次。個人餘額＝Σ（所有**未清帳**月份 m）［補入額(m ≥ 加入月才有) ＋ 該月淨變動］。個人期初餘額廢用。
  - **該月淨變動**（依帳目 `occurred_on` 歸月）＝ Σ本人私人收入 − Σ本人私人支出 − Σ本人**未結算**代墊的全額 − Σ**已結算**共同支出中本人的份額（每筆以**最大餘數法**把 `entry_splits.share` 取整，使該筆各成員整數份額合計恰等於金額；同小數以 member_id 決定先後，與結算 RPC 同法）。已結算筆對付款人也只算自己的份額（等於「記帳時扣全額、結算後拿回全額再扣份額」）。共同收入與共同錢包支出不進個人餘額。
  - 例：補入額 10,000，上月淨變動 −10,200 → 上月月末 −200；本月補 10,000 → 現在 9,800；清完上月 → 上月整項自公式移除 → 10,000。
  - 改補入額即時套用所有未清帳月份；已清帳月份以 `month_close.details` 快照為準不再變。
- **預算只有共同一套**，每分類一個。**每分類每月只設定一次**（金額 > 0，設定後不可改、不可刪、不可退回）；不跨月、不自動設定。
- **已花**＝該分類當月**所有共同支出**（共同錢包付＋代墊都算），私人不算；剩餘＝max(0, 預算 − 已花)；**超支**＝max(0, 已花 − 預算)，隨時重算。花費＝所有共同支出。
- **連動**：
  - 共同錢包付 → 只扣共同餘額。
  - 代墊 → 記帳當下扣付款人個人餘額全額；結算全簽完那一刻改為每人各扣自己份額（歸帳目所在月）。
  - 私人帳目只動本人個人餘額；共同收入進共同餘額。
- **清單只是購物車**：未結帳前不影響任何餘額；勾選結帳產生支出那一刻才依付款來源扣共同餘額或付款人個人餘額。
- 預算頁：頂部四數字：共同餘額、本月預算合計、本月共同支出、本月超支；每分類一列：預算、已花、剩餘／超支；點列開 sheet「設定本月預算」（該分類本月已設定則顯示金額、不可改）。進入新月份若該月無預算，頂部提示「設定本月預算」，可一鍵複製上月（只補尚未設定的分類）。

### 清帳（v1.4，ADR-0008）
- **目的**：對指定「已結束月份」做三方（每位成員 ↔ 共同帳戶）對帳，列出誰該給誰多少錢，然後把該月對個人餘額的影響歸零（個人餘額回復到每月設定值）。轉錢與記共同收入**全部人工**，app 不動共同餘額。
- **可清條件**（RPC 與前端都擋）：(1) 月份依台北時間早於當月；(2) 必須是**最早尚未清帳的月份**（首次＝最早有帳目或成員加入的月份；之後＝上次清帳月＋1）；(3) 該月所有拆帳（`scope=shared`、`kind=expense`、`payer` 非 null、`split_method≠common`、**且有分攤列**）皆為 `settled`（沒有分攤列的拆帳筆結算不會撿，清帳也不擋，與結算 RPC 同判準）；(4) 同月只清一次。任一成員可執行，不需多簽，不可撤銷。
- **明細**（預覽與紀錄同一份，RPC `month_close_preview` 與 `close_month` 同一段 SQL 算）：每位成員一列：補入額、淨變動、月末餘額；月末餘額 > 0 → 「{成員} 轉 {金額} 給共同帳戶」，< 0 → 「共同帳戶補 {成員} {金額}」，＝0 → 「免處理」。另列該月共同餘額變動供對照。
- **效果**：寫入 `month_close`；該月自個人餘額公式移除；**該月及更早的所有月份**帳目與撥款鎖定（鎖定判準＝`occurred_on` 月 ≤ 最後清帳月，補記到清帳月之前也擋，否則那些月份永遠清不到）。
- 清帳頁確認前必有二次確認（不可撤銷；誤按只能由管理者在雲端 SQL 刪列）。
- **清帳頁**（設定頁「清帳」列 → `/settings/closes`）：頂部「清帳 YYYY／MM」按鈕（依可清條件決定 enabled；不可清時一行原因：「本月尚未結束」「有拆帳尚未簽完」「沒有可清的月份」）→ 點開預覽 sheet（明細列＋確認鈕）→ 確認呼叫 `close_month` → 列表刷新。下方清帳列表：每筆一列（月份、清帳者、時間、各成員月末餘額摘要），點列展開完整明細。

### 清單
- 購物項目：名稱、店家分組、預估金額、分類、負責人。待辦：無金額無分類，可指派、到期日（app 內標示，不推播）。
- 勾選：單項→sheet 只有一個金額欄（預填預估）；多項→每項實際金額欄、總計唯讀自動加總。產生 shared expense（分類、名稱帶入，項目成細項，預設 payer/split 同新增表單預設；v1.4 起無資金來源）；主筆金額＝加總，不可手改（v1.1）。

### 搜尋
- 比對 line_item.name、entry.note、list_item.title（ILIKE／pg_trgm）。結果以細項為單位：品項、金額、日期、分類、備註，點開主筆；同名品項附價格折線。

### 帳本與成員
- 第一次登入自動建帳本；設定頁顯示邀請碼、可輸入邀請碼加入他人帳本、可建新帳本與切換。
- 設定頁內容：帳本切換、邀請碼、成員、default_ratio、餘額設定（共同期初餘額一個＋我的每月補入額；個人期初餘額 UI 拿掉）、清帳（子頁 `/settings/closes`）、分類管理（子頁 `/settings/categories`）、外觀。預算已是獨立 Tab，不另設入口。

## 驗收總表

| 模組 | 證據 |
| --- | --- |
| schema/RLS/RPC | `supabase db reset` 全綠；pgTAP 或 SQL 腳本驗 RLS（私人不可見）、結算多簽、settled 鎖 |
| 前端 | `flutter analyze` 無錯；`flutter test` 全綠；Mike 地端手測（Flutter Web hot reload） |
| 結算 | 兩帳號 e2e：A 代墊、B 簽、狀態 settled、entry 鎖住 |
| 統計 | 已知資料集算出的三條線（花費、可用餘額、超支）與 SQL 手算一致 |
| 餘額連動 | 兩帳號 e2e：補入額各 10,000；代墊 1,000 均分 → 付款人個人 9,000；簽完 → 付款人 9,500、對方 9,500、共同不變 |
| 清帳 | SQL 測試：不可清當月／跳月／有未簽拆帳；清後 `month_summary` 個人餘額回到補入額、鎖月 trigger 擋新增／修改／刪除；前端 widget 測試預覽明細三種方向文案 |
| 預算影子 | SQL 測試：同分類同月第二筆被 unique 擋、amount ≤ 0 被擋、UPDATE／DELETE 42501；已花含代墊 |

## 已決策清單

ADR-0001 資料模型（細項附註、分攤掛主筆）；ADR-0002 結算多簽與鎖定；ADR-0003 私人／共同範圍；ADR-0004 rollover 與餘額（已被 0006、0007 取代）；ADR-0005 平台與預設值；ADR-0006 信封制（部分被 0007 取代）；ADR-0007 帳務規則 v1.3（「用預算支付」、信封預扣、撥款可退回、個人期初餘額被 0008 取代）；ADR-0008 帳務規則 v1.4。
