# WIP — accounting 記帳 app（/mega）

更新：2026-09-04 晚（帳務規則 v1.4 /mega 探路段：decision 清單待裁）

## 任務背景與目標

夫妻共同記帳 Flutter Web/iOS app（Supabase 後端）。spec：`docs/specs/ledger.md`（v1.3，帳務規則見「餘額與預算」節），決策 `docs/adr/0001–0007`。波 1＝四個畫面（假資料）＋ Supabase schema/RLS/RPC；波 2＝接雲端與信封制。

## 已完成

- **波 1 已合併 dev（2026-09-03，一顆 commit 422fe71）**：四頁假資料版＋DB 23 支 migration＋SQL 測試；三 reviewer 全過。
- **波 2 五切片全部合入 feature/wave2**（各經 code review；db 另過 db／security reviewer）：
  - db（31d963f）：budget_allocation／entries.funding，migration 0024；雲端 dev 已 push 24 支＋smoke 掃描全過。
  - domain（68986c7）、form（cf29a18）、trend（8568f68）、budget-ui（c60adf3）、死碼清理（5e93f16）。
  - data（bcd2745 合入，工人 commit 7f70df0＋修復輪 44dff42）：email 登入、快照式資料層、Realtime、結算走 RPC、邀請碼。
- feature/wave2 親驗（2026-09-03 本 session）：`flutter analyze` 0 issues、`flutter test` 368 過（~2 skip＝INTEGRATION 契約測試，需地端棧）。
- `docs/specs/db-contract.md` 是 DB 契約。

## 需求／波次看板

| 需求/波次                | 階段   | feature 分支          | 切自 dev | 依賴 | review 現況 |
| ------------------------ | ------ | --------------------- | -------- | ---- | ----------- |
| 波 1 畫面＋DB            | 已合併 | feature/wave1（已刪） | b4d157f  | 獨立 | 全過        |
| 波 2 接 Supabase＋信封制 | 已合併 | feature/wave2（已刪） | 72b5952  | 波 1 | 全過（Mike 裁示直接合） |

## 收斂時進行中的工人

無；wt/wave2/*／feature/wave2 分支與 worktree 已三清（squash 後 -d 不認、經零差異驗證用 update-ref 刪）。

## 決策

- 已解：ADR-0001～0007（0007＝帳務規則 v1.3）。
- 已解（未入 ADR，記 spec）：UI 互動原則、資訊密度、比例逐筆可調、清單＝購物車。
- 已解（波 2 裁示）：資料層 A 快照式、provider 介面不變；先 email/password 登入，Apple 待 Mike 設定；雲端 dev db push 已授權。
- 尚未明朗：無。

## 待 Mike 裁示

- 雲端 dev＋prod 關 signup：帳號建好後在 dashboard 關（anon key 公開，任何人可註冊，RLS 擋資料）。建議：家人帳號建完就關。
- 統計第一列 6 顆按鈕 390px 偏擠：建議看實機；不順眼一行改回兩列。
- v1.4 review 留下的三題已依「兩人客製」原則收掉（2026-09-05 Mike 裁示）：payer 可指向他人不限制；時區裝置 vs 台北不處理；可清條件三份實作留著（ledger 記一行）。
- SQL 測試 `supabase/tests/run.sh` 需地端 DB——「不再起地端 DB」後是否保留／改為只在 migration 時臨時起一次？建議：只在有新 migration 時臨時起棧跑一次再關。

## 手測回饋迭代（2026-09-03～04，全部已合入 feature/wave2 並過測試）

### 09-03 晚～09-04 新增（皆在 feature/wave2，widget 369 綠＋導覽 e2e 全綠）

- 表單四關精靈（類型分類金額／日期備註細項／進階／確認）＋金額 0 鎖下一步＋細項空列規則；編輯改單頁明細 hub（點欄位開單欄彈窗）。
- 帳目列表：渲染分頁 20 筆漸進、分類/日期區間篩選（chips 可捲不截斷）、金額排序、預設 created_at 倒序（Entry 補 createdAt）。
- 統計月摘要兩行；預算自寫雙層水波（慢頻細波、逐條 seed 異步、二輪調參）；左滑動作圓形 icon 共用件；登入頁簡潔化＋accounting（Pacifico）標題。
- 首登關卡制（二選一→輸入→建立後分享關：邀請碼大字＋share_plus 系統分享/剪貼簿 fallback）；router 放行 /onboarding 停留。
- 新手互動導覽 12 步（tutorial.dart）：亮區光暈可點、其餘全鎖、點 tab/齒輪/分類管理真導頁自動前進、清單步真開新增 sheet（advanceOnTap＋NavigatorObserver 雙路徑）、下一步收 sheet；首次進帳目自動開（prefs tutorialDone）。修：FAB heroTag 撞名、go_router push 不反映 uri（改 last.matchedLocation）、web focus 崩潰（卡片 ExcludeFocus＋逐步換 key）。
- 輪詢改 30 秒＋背景暫停（appForegroundProvider），egress 風險解除。
- e2e：`tool/e2e/tutorial_e2e.sh`（playwright-cli＋Flutter semantics，註冊→建帳本→分享→導覽 12 步全驗；E2E_SESSION／url 可參數化）。已知限制記 ledger：modal 外 semantics inert（螢幕閱讀器卡購物清單步）。

- 表單頂對齊＋等高、個人視角不計共同收入（bug 修）、日小計改損益符號。
- 預算頁水位長條圖（動畫）、清單拿掉待辦、列表左滑編輯/刪除（帳目＋分類）。
- 新增彈窗步驟精靈（購物項目、分類）、分類選擇改垂直滾輪、帳目表單七步精靈（確認明細才儲存）。
- 資料層：5 秒輪詢保底（polling.dart）；衍生數字改 DB 計算——migration 0025 `month_summary`
  （SQL 測試＋rls 白名單，雲端 dev 已 push、anon 401 驗過），預算頁／撥款 sheet／統計月摘要吃 server 值。
- 驗證債見 ledger（趨勢逐桶仍前端算、settled_at UTC 邊界、複製上月金額前端加總）。

## 09-04 晚（TestFlight 迭代）

- 沖銷/被沖銷連刪除也鎖（滑動整排拿掉＋明細選單拿掉）。
- 邀請流程：系統分享做了又退（Mike 裁示「停」）→ 首登分享關改「複製邀請碼」鈕；`lib/app/invite_share.dart` 已刪。邀請碼欄位（首登＋設定頁）加 `FilteringTextInputFormatter.allow([a-zA-Z0-9])`——貼上夾空白吃名額、10 碼變 9 碼有效的實測 bug。
- ledger 新增「iOS 上架前審查遺留」節：帳號刪除（外部測試/上架必補）、隱私政策入口、token 進 Keychain、debugPrint、obfuscation。
- 測試 377 綠；web 最新 build stamp 0904-1851（8787/8788 都已刷新）。

## 09-04 下午～傍晚新增（全部落 dev、逐輪過全套測試）

- 分類選擇改橫向無限循環滾輪（viewport 1/5、點擊聚焦動畫；`lib/app/category_wheel.dart`），表單／編輯／結帳共用。
- 篩選 chips 自建 pill 取代 InputChip（截斷免疫）；全站金額欄 digitsOnly＋數字鍵盤。
- 修正筆功能移除 → 「編輯＝沖銷重記」全面化：所有編輯走 原筆保留＋反向沖銷筆＋新筆 三筆軌跡（note 帶 #id前8碼 配對；`reversal.dart`）；列表被沖銷紅、沖銷藍、劃線；**沖銷/被沖銷不可編輯不可刪**（列表滑動整排拿掉＋明細鉛筆/刪除拿掉）。
- 撥款流水固定 5 列高可捲、細項固定 3 列倒序可捲；列表點擊＝唯讀明細（disable、細項點擊向下展開於細項列正下方）；左滑刪除取代 X 按鈕。
- 帳目列表家庭/個人分離：個人 tab 只看 private own 筆。
- 鍵盤彈起表單頂對齊不擋欄位；SW controllerchange 自動 reload＋BUILD_STAMP（設定頁頁腳可對版本）。
- e2e 固定測試帳號 e2e-tutorial@example.com；Docker supabase 棧瘦身統一。
- **紀律**：release build 會弄壞同目錄跑著的 dev server → 每次 `tool/build_web.sh` 後必重啟 8787；ngrok 綁 8788（release 靜態）。
- **iOS/TestFlight（首發完成，2026-09-04 晚）**：build 1～6 全數上傳成功，最新 **0.1.0 (6)**（stamp ios-0904-1850）。歷程：b1 首傳（90068 minOS 警告）→ b2 icon v1＋minOS 15 → b3 icon 定稿 v3（貓圖 duotone＋顆粒，`~/mike/icons/icon-v3.png`）→ b4 系統分享版（**作廢不發佈**）→ b5 分享退回複製鈕 → b6 邀請碼欄位濾非英數。ASC app「accounting by mike」（id 6808578728）；**internal 群組 `family`**（自動發佈、成員 mike504110403＋heart5588mem，邀請信已重發、等接受）；external 群組建過兩次都已刪（公開連結路線棄用——要過 beta review）。90068 警告已解。詳細：bundle `com.mikelin.accounting`（Team DDMW7327JC）、SIWA capability＋entitlements、原生 Sign in with Apple（nonce＋signInWithIdToken；iOS 登入頁只放 Apple）、dist 憑證＋AppStore profile（fastlane cert/sigh）、`tool/build_ios.sh` 注入 prod。**Supabase prod 建好**：ref jcvichjhryczvlvkdsjj（東京）、26 migrations 全推、autoconfirm 開、Apple provider 開；憑證在 `~/mike/supabase/prod.env`、ASC 金鑰在 `~/mike/asc/`（Admin key 7FCJX2X2C7）。上架前雙審查（app-store-review＋OWASP）無 BLOCKER，M-1/m-5/m-10 已修（0904-1714）；M-2 帳號刪除、M-3 隱私政策、M-4 token 進 Keychain 記 ledger。ASC app record「accounting by mike」（id 6808578728）已建，ipa 已上傳，等 processing → 掛內部測試群組。

## 帳務規則 v1.4 調整（/mega，2026-09-04 晚起）

Mike 十題全裁（2026-09-04）：**ADR-0008**＋**spec v1.4** 已 commit 在 `feature/rules-v14`（161e207）。決策摘要：清帳只列明細＋動個人餘額；結算份額依 occurred_on 逐筆歸月、清帳前該月拆帳全簽完；個人期初餘額廢除；補入額加入月起算、改值套用未清月；已花＝所有共同支出含代墊；**預算每分類每月只能設定一次（不增不減）**；funding 整個 drop；清帳按序／一次／不可撤銷／不多簽／RPC；已清月鎖定；共同餘額不扣信封。

scout 落檔 `.claude/scout-v14-balance.md`／`scout-v14-budget.md`（未入 git，波次結束刪）。brief 在 scratchpad `brief-db-v14.md`／`brief-form-nofunding.md`。

### 波次看板

| 波次／任務 | 階段 | 分支 | 切自 | 依賴 | 工人 | review |
| --- | --- | --- | --- | --- | --- | --- |
| feature/rules-v14（需求） | **已合 dev（2c6a020，一顆）；feature 三清**；雲端 dev／prod 已套 20260904000200（dev 撥款 18→7 合併、prod 2→2）；Mike 手測改在 TestFlight（prod）進行 | feature/rules-v14 | dev 5064f8f | — | — | Mike 手測站：整需求合 dev 前一次做（波 1 表單切片為純移除，延後到波 2 完成後） |
| 波1 DB：migration 0027 合一支、month_closes、close_month/preview RPC、鎖月 trigger、entry_member_effects view、month_summary 重寫、SQL 測試 | **已合入 feature（ad6c814，merge 06b3486）** | wt 已清 | feature 161e207 | 獨立 | 已收工 | db／security／code 三 reviewer 兩輪複審＋MINOR 確認全過（累計 28 個變異）；review 檔留 scratchpad |
| 波1 表單／結帳／沖銷去 funding UI（不動 model） | **已合入 feature（5815dcd）** | wt 已清 | feature 161e207 | 獨立 | 已收工 | code-reviewer 過（1 MAJOR 修復輪後複審過）；未指派 MINOR：沖銷對話框「預算一併回退」文案→F3；`_save` orig!=null 分支無測試（PLAUSIBLE 不可達） |
| 波2 F1 domain/data：models 去 Funding、Member.monthlyTopup、MonthClose、balance_math 重寫、repository 介面＋兩實作、month_summary.dart 新鍵、errors.dart、消費者最小對齊 | **已合入 feature（21e04b2，merge 45356e5）** | wt 已清 | feature 06b3486 | 依賴波1 | 已收工 | code-reviewer 過（0 MAJOR，7 MINOR 修畢確認）；INTEGRATION 43 綠 |
| 波2 F3 預算頁：頂部四數字、撥款 sheet 改「設定本月預算」一次性、複製上月只補未設定、tutorial 導覽文案、沖銷對話框文案 | **已合入 feature（5509ba9，merge 6a11747）** | wt 已清 | feature 45356e5 | 依賴 F1 | 已收工 | code-reviewer 過（1 MAJOR 修復輪重審過、MINOR 確認） |
| 波2 F4 設定頁：每月補入額取代個人期初、清帳入口＋ `/settings/closes` 清帳頁（列表＋預覽＋二次確認）、鎖月 UI | **已合入 feature（06c1048，merge 1473d1e）** | wt 已清 | feature 45356e5 | 依賴 F1 | 已收工 | code-reviewer 過（0 MAJOR，6 MINOR 修畢確認；累計 43 變異）；INTEGRATION 45 綠 |
| 波2 F5 統計：趨勢線改共同餘額／個人餘額新公式、月摘要吃新鍵、已清月看快照／未來月投影 | **已合入 feature（d1e8774，merge 014d4d9）** | wt 已清 | feature 45356e5 | 依賴 F1 | 已收工 | code-reviewer 過（0 MAJOR，7 MINOR 修畢確認） |

### Mike 手測站（2026-09-05 起）
- 入口：dev server **8789**（feature worktree，`--dart-define` 連地端 127.0.0.1:54321；**不要用 8787**——那是舊 session 的 dev server、指雲端 dev）。完整清單 `accounting-feature-rules-v14/.claude/handtest-v14.md`（21 條）。地端 DB 已 run.sh 重置成 v1.4 乾淨 seed；帳號 mike@test.local／wife@test.local，密碼 password。

### 手測清單摘要
- 預算頁：六位數金額月份看頂部三欄是否折行（reviewer PLAUSIBLE）；未設定但有花費的分類列（seed 住房）紅條＋灰標視覺是否順眼；已設定列點開唯讀、過去月「已過期」。
- 清帳頁：三種 disabled 原因、預覽三方向文案、二次確認、B 帳號清下一月、Realtime 同步、同時清帳競爭（工人 15 條清單存 scratchpad 回報）。
- 統計：切視角 legend、已清月個人卡讀快照、未來月投影小字（個人視角）；非月顆粒度已清月斷線時 trackball tooltip 是否仍列「個人餘額」（reviewer PLAUSIBLE）。
- 設定：兩列餘額設定共用 sheet、補入額 1 億上界錯誤。

### 部署順序（ledger 定則＋db review M1/M2）
**v1.4 migration 與前端 build 必須同一波上**：新 `month_summary` 移除 `shared_available`／`envelope_total`，舊 build 的 `MonthSummary.fromJson` 硬轉會炸（首頁／預算頁全掛），TestFlight 舊 build 無法強更→push migration 後立即發新 web build 並上傳新 iOS build；push 後立刻呼叫一次 `month_summary` 驗。**push 前**：(1) 對 prod／dev 各 `pg_dump -t budget_allocation -t entries` 留檔記進 wip；(2) migration 自帶 `archive.budget_allocation_v13` 備份表；(3) 先在 prod 副本跑一次並 diff 撥款列數／金額總和。既有負撥款列由 migration 合併／刪除（原始列快照在 `archive.budget_allocation_v13`）。**push 前查 `supabase_migrations.schema_migrations`**：合併檔沿用版本號 `20260904000200`，若雲端曾套過舊拆分檔會整支跳過（db review N3）。

## 下一步

1. /ship：052ecfa 已推 origin；之後 **24 顆 commits 未推**（至 e16a6da），等 Mike 說「推」。
2. ~~replica identity full migration~~ 已完成（0026 雲端已 push＋驗證、db review 過、前端拆補丁）。
3. 待辦池：Mike/家人接受 TestFlight 邀請＋實機驗（build 6）、iOS home indicator padding（5 個 sheet）、帳號刪除＋刪帳本 RPC 合併做、隱私政策頁、token 進 Keychain、關 signup、螢幕閱讀器導覽卡步、janitor 品質清潔（settings_page 拆檔等）、UI 現代化掃尾（隨 Mike 截圖迭代）。

## 環境備忘

- 雲端 Supabase：org accounting、dev 專案 ref wxqbxsagfvtxnvaloklr（東京），DB 密碼在 `~/.config/accounting/supabase.env`；app 預設連它（`lib/data/supabase_client.dart` dart-define 可覆寫，`USE_MOCK=true` 走記憶體）。
- 既有雷：`~/.claude/ledgers/accounting.md`（波 2 DATA review 順路發現未處理：settlement_signers 未讀、InMemory 單帳本、settings_page 810 行等）。
- 看畫面：`tool/dev.sh 8787`（hot reload）；給手機看：`flutter build web --release` → `python3 -m http.server 8788 -d build/web` → `ngrok http 8788`。
- 地端 Supabase 棧（僅 INTEGRATION 測試／DB 測試用）：`supabase start`；測試 `supabase/tests/run.sh`（含 reset，會清 contract-* 殘留）。
