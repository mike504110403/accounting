# WIP — accounting 記帳 app（/mega）

更新：2026-09-04 傍晚（手測迭代收斂；iOS TestFlight 首發流程進行中）

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
- ~~Apple 登入~~ 已解：原生 id-token 流程不需 Services ID，prod/dev provider 已開。

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

## 09-04 下午～傍晚新增（全部落 dev、逐輪過全套測試）

- 分類選擇改橫向無限循環滾輪（viewport 1/5、點擊聚焦動畫；`lib/app/category_wheel.dart`），表單／編輯／結帳共用。
- 篩選 chips 自建 pill 取代 InputChip（截斷免疫）；全站金額欄 digitsOnly＋數字鍵盤。
- 修正筆功能移除 → 「編輯＝沖銷重記」全面化：所有編輯走 原筆保留＋反向沖銷筆＋新筆 三筆軌跡（note 帶 #id前8碼 配對；`reversal.dart`）；列表被沖銷紅、沖銷藍、劃線；**沖銷/被沖銷不可編輯不可刪**（列表滑動整排拿掉＋明細鉛筆/刪除拿掉）。
- 撥款流水固定 5 列高可捲、細項固定 3 列倒序可捲；列表點擊＝唯讀明細（disable、細項點擊向下展開於細項列正下方）；左滑刪除取代 X 按鈕。
- 帳目列表家庭/個人分離：個人 tab 只看 private own 筆。
- 鍵盤彈起表單頂對齊不擋欄位；SW controllerchange 自動 reload＋BUILD_STAMP（設定頁頁腳可對版本）。
- e2e 固定測試帳號 e2e-tutorial@example.com；Docker supabase 棧瘦身統一。
- **紀律**：release build 會弄壞同目錄跑著的 dev server → 每次 `tool/build_web.sh` 後必重啟 8787；ngrok 綁 8788（release 靜態）。
- **iOS/TestFlight（進行中）**：bundle `com.mikelin.accounting`（Team DDMW7327JC）、SIWA capability＋entitlements、原生 Sign in with Apple（nonce＋signInWithIdToken；iOS 登入頁只放 Apple）、dist 憑證＋AppStore profile（fastlane cert/sigh）、`tool/build_ios.sh` 注入 prod。**Supabase prod 建好**：ref jcvichjhryczvlvkdsjj（東京）、26 migrations 全推、autoconfirm 開、Apple provider 開；憑證在 `~/mike/supabase/prod.env`、ASC 金鑰在 `~/mike/asc/`（Admin key 7FCJX2X2C7）。上架前雙審查（app-store-review＋OWASP）無 BLOCKER，M-1/m-5/m-10 已修（0904-1714）；M-2 帳號刪除、M-3 隱私政策、M-4 token 進 Keychain 記 ledger。ASC app record「accounting by mike」（id 6808578728）已建，ipa 已上傳，等 processing → 掛內部測試群組。

## 下一步

1. /ship：052ecfa 已推 origin；之後整個下午的 commits（至沖銷鎖刪＋iOS 設定）未推，等 Mike 說「推」。
2. ~~replica identity full migration~~ 已完成（0026 雲端已 push＋驗證、db review 過、前端拆補丁）。
3. 待辦池：TestFlight build 掛測試群組＋Mike 實機驗、iOS home indicator padding（5 個 sheet）、帳號刪除＋刪帳本 RPC 合併做、隱私政策頁、token 進 Keychain、關 signup、螢幕閱讀器導覽卡步、janitor 品質清潔（settings_page 拆檔等）、UI 現代化掃尾（隨 Mike 截圖迭代）。

## 環境備忘

- 雲端 Supabase：org accounting、dev 專案 ref wxqbxsagfvtxnvaloklr（東京），DB 密碼在 `~/.config/accounting/supabase.env`；app 預設連它（`lib/data/supabase_client.dart` dart-define 可覆寫，`USE_MOCK=true` 走記憶體）。
- 既有雷：`~/.claude/ledgers/accounting.md`（波 2 DATA review 順路發現未處理：settlement_signers 未讀、InMemory 單帳本、settings_page 810 行等）。
- 看畫面：`tool/dev.sh 8787`（hot reload）；給手機看：`flutter build web --release` → `python3 -m http.server 8788 -d build/web` → `ngrok http 8788`。
- 地端 Supabase 棧（僅 INTEGRATION 測試／DB 測試用）：`supabase start`；測試 `supabase/tests/run.sh`（含 reset，會清 contract-* 殘留）。
