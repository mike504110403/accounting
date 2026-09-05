# ADR-0009 帳務規則 v1.5（單一帳目、手動補入、照補入三方清帳）

日期 2026-09-05　狀態 accepted（取代 ADR-0002 結算多簽、ADR-0003 私人／共同範圍、ADR-0006 信封、ADR-0008 的額度制與比例分攤；ADR-0001 細項、ADR-0005 平台與預設值、ADR-0008 的預算影子與鎖月仍有效）

## 情境

v1.4 上 TestFlight 後 Mike 手測（2026-09-05）重述帳務語意：概念上只有一種帳目＝家庭支出，只區分「買的東西類型（分類）」與「誰先付錢」；個人補入概念上也是預算——個人先預留出來付共同支出的錢；分類預算是影子紀錄所有支出、用來審視家庭開銷；每月清帳＝使用者依明細把真實的錢互相清償，清償後回到設定狀態。v1.4 的私人範圍、逐筆分攤、結算多簽、每月自動補入額、共同期初餘額都與這個語意衝突，且讓「回到設定狀態」有兩套解釋。

## 決策（office-hours 四題＋grilling 四題，2026-09-05）

1. **私人範圍與個人收入整個廢掉**：帳目只有家庭支出與共同收入。`entries.scope` drop；RLS 可見性回到「同帳本成員全部可見」。
2. **個人補入改手動**：每人每月自己按「補入」記金額（可多筆、可備註、可一鍵複製上月合計），存 `personal_topups`；`members.monthly_topup` 廢。未清月的補入可刪除，已清月鎖定。
3. **結算多簽與逐筆分攤廢掉**：每筆支出只記「誰先付」（`payer_id`：成員或 null＝共同錢包）；`split_method`、`entry_splits`、`settlements`／`settlement_entries`／`settlement_approvals`／`settlement_signers` 全部 drop；`ledgers.default_ratio` 廢。
4. **清帳照補入三方對帳**：清帳月每位成員「月末＝Σ該月補入 − Σ該月自己先付」；> 0 轉給共同帳戶、< 0 共同帳戶補、＝ 0 免處理；另列該月共同錢包支出合計對照。公平由各自補入多少決定。清帳確認頁提供「一鍵記共同收入」（預設勾，金額＝各成員應轉入合計 − 應補出合計，> 0 才記；記為該清帳月最後一天的共同收入、分類「清帳轉入」）；共同餘額仍只由收入紀錄與共同錢包支出推動。清完該月補入與先付自「補入剩餘」公式移除＝回到設定狀態。
5. **統計無視角**：圓餅依分類／依付款人（共同錢包算一片）；趨勢線：花費（桶內全部支出）、共同餘額（桶末水位）、每人補入（該桶補入合計，僅月／年顆粒度）。
6. **編輯維持沖銷重記**（ADR-0008 第 9 條軌跡形式），已清月一律鎖；沒有結算鎖，其餘欄位皆可經沖銷改。
7. **既有資料清空重來**：migration 先 truncate `entries`（含細項、分攤）、`budget_allocation`、`list_items`、settlements 三表、`month_closes`；帳本、成員、分類保留；`opening_balance_shared`、`monthly_topup` 直接 drop 不轉換。dev／prod 同一支。
8. **新增支出預設「我先付」**（記帳者），共同錢包手動切；收入無付款人。

## 三個數（每個只有一個來源）

| 數                       | 定義                            | 動它的事件                                  |
| ------------------------ | ------------------------------- | ------------------------------------------- |
| 共同餘額                 | Σ共同收入 − Σ共同錢包付的支出   | 收入紀錄、`payer_id is null` 的支出         |
| 個人補入剩餘（每人每月） | Σ該月補入 − Σ該月本人先付的支出 | `personal_topups`、`payer_id = 本人` 的支出 |
| 分類預算剩餘（每月影子） | 預算 − 該分類該月全部支出       | `budget_allocation`、任何支出               |

## 後果

- DB：drop `entries.scope`／`split_method`／`settled_state`／`is_adjustment` 以外的結算欄與 `settlement_state` 類 enum；drop `entry_splits`、settlements 四表、`ledgers.default_ratio`／`opening_balance_shared`、`members.monthly_topup`／`opening_balance_personal`；新表 `personal_topups(ledger_id, member_id, month, amount > 0, occurred_on, note, created_by)` 只能寫自己那列、鎖月 trigger 同帳目；`month_summary`／`month_close_preview`／`close_month` 依新公式重寫（`entry_member_effects` 縮成「先付」一項）；`close_month` 加 `p_record_income boolean`；`upsert_entry` 去 splits；RLS 去私人可見性；`initiate_settlement` 等 RPC drop。
- 前端：帳目頁去視角切換、列表顯示付款人 chip；表單折疊區只剩「誰先付」；`balance_math`／`view_math`／`settlement_math` 重寫或刪除；預算頁加「個人補入」區塊（每人：本月補入合計、先付、剩餘；補入 sheet；按月切換）；統計頁去視角、趨勢三組線；清帳頁明細改新口徑＋「一鍵記共同收入」勾選；設定頁去分攤比例與餘額設定；清單結帳只選誰先付；待簽核卡片與結算流程整組移除。
- 部署：migration 會清資料並 drop 舊表，**舊 build 對新 DB 必炸**——先 push migration 再上 build，兩人同時更新；build 8 與成員名稱功能一起上。
