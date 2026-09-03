# WIP — accounting 記帳 app（/mega）

更新：2026-09-03

## 任務背景與目標

夫妻共同記帳 Flutter Web/iOS app（Supabase 後端）。spec：`docs/specs/ledger.md`（v1.2，含 UI 互動原則、資訊密度、預算信封制），決策 `docs/adr/0001–0006`。波 1＝四個畫面（假資料）＋ Supabase schema/RLS/RPC；波 2 起接雲端與信封制。

## 已完成

- **波 1 已合併 dev（2026-09-03，一顆 commit）**：帳目／統計／清單／設定四頁（假資料、三輪 Mike 手測回饋）、DB 23 支 migration＋seed＋4 個 SQL 測試檔＋run.sh、共用件（主題含白天／夜晚、MonthAppBar／MonthTitle 年月雙滾輪＋箭頭、ViewModeToggle、themeModeProvider）。code／db／security reviewer 全過；`flutter analyze` 無、`flutter test` 205 綠。
- `docs/specs/db-contract.md` 是波 2 的 DB 契約。

## 需求／波次看板

| 需求/波次                | 階段   | feature 分支          | 切自 dev | 依賴 | review 現況 |
| ------------------------ | ------ | --------------------- | -------- | ---- | ----------- |
| 波 1 畫面＋DB            | 已合併 | feature/wave1（已刪） | b4d157f  | 獨立 | 全過        |
| 波 2 接 Supabase＋信封制 | 未開   | —                     | —        | 波 1 | —           |

## 收斂時進行中的工人

無。

## 決策

- 已解：ADR-0001～0006（細項附註、結算多簽、私人／共同、rollover、平台預設、信封制）。
- 已解（未入 ADR，記 spec）：UI 互動原則、資訊密度、比例逐筆可調、清單＝購物車。
- 已解（大腦依預授權規則裁，可逆 UI）：期初餘額摘要列維持短格式「共同120,000／我50,000」；reviewer 估真機 Roboto 約 182px < 可用 248px 不截斷，測試字型下 7 位數才會截。
- 尚未明朗：信封制「每月自動撥款」與 rollover 退回的 UI 形狀（波 2 brief 前 grill）。

## 待 Mike 裁示

- 統計第一列 6 顆按鈕在 390px 偏擠：建議先看實機；不順眼改回兩列（一行改動）。

## 下一步

1. /ship：dev 尚未 push（remote 只有 main 的 Initial commit）；Mike 授權後 push dev。
2. 波 2 brief 前先 grill 信封制 UI（每月撥款、rollover 退回、entries.funding 選擇的操作形狀）。
3. 波 2 DB 起手：新開 feature worktree，link 雲端 dev 專案（ref 見下）`db push`，之後跑 `supabase/tests/rls.sql` 掃描當 smoke test（supabase_admin 預設 ACL 只能在雲端驗）。
4. 波 2 app 端：Apple 登入、repository 實作取代 mock_data、Realtime；信封制依 spec v1.2／ADR-0006（allocation 表、entries.funding、預算頁重做、趨勢線改水位）。

## 環境備忘

- 雲端 Supabase：org accounting、dev 專案 ref wxqbxsagfvtxnvaloklr（東京），密碼在 `~/.config/accounting/supabase.env`。
- 既有雷：`~/.claude/ledgers/accounting.md`（含設定頁 review 順路發現、home indicator padding、「波 2 接後端」佔位字串）。
- 看畫面：`tool/dev.sh 8787`（hot reload）；給手機看：`flutter build web --release` → `python3 -m http.server 8788 -d build/web` → `ngrok http 8788`。
- 地端 Supabase 棧：`supabase start`；測試 `supabase/tests/run.sh`。
