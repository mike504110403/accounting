#!/usr/bin/env bash
# 新手教學 e2e（Mike 指定 2026-09-03）：Playwright 實走「註冊→建帳本→分享關→互動導覽 12 步→回帳目」。
# 前置：release build 已 serve 在 $APP_URL（預設 8788）；連雲端 dev（autoconfirm 開）。
# 用法：tool/e2e/tutorial_e2e.sh [url]
set -euo pipefail
S="${E2E_SESSION:-e2e-tut}"
APP_URL="${1:-http://127.0.0.1:8788}"
PW() { playwright-cli -s=$S "$@"; }
ref() { # ref '<pattern>' → 第一個符合「整行」的節點 ref
  PW snapshot 2>/dev/null | grep -E "$1" | grep -oE '\[ref=e[0-9]+' | grep -oE 'e[0-9]+' | head -1
}
must() { # must '<pattern>' '<訊息>'
  if ! PW snapshot 2>/dev/null | grep -qE "$1"; then echo "FAIL: $2"; exit 1; fi
  echo "OK: $2"
}
click_ref() { local r; r=$(ref "$1"); [ -n "$r" ] || { echo "FAIL: 找不到 $1"; exit 1; }; PW click "$r" >/dev/null; }

PW delete-data >/dev/null 2>&1 || true
PW open "$APP_URL" >/dev/null
sleep 8
# Flutter web 要先開 semantics 才有可點的節點
PW eval "() => { const el = document.querySelector('flt-semantics-placeholder'); if (el) el.click(); return 'ok'; }" >/dev/null
sleep 3

ACCT="e2e-tut-$(date +%s)@example.com"
echo "帳號: $ACCT"
click_ref 'textbox "Email"'; PW type "$ACCT" >/dev/null
click_ref 'textbox "密碼"'; PW type "testtest123" >/dev/null
click_ref 'button "註冊新帳號"'; sleep 6
must 'button "建立新帳本' '首登關 0：二選一'
click_ref 'button "建立新帳本'; sleep 2
click_ref 'button "建立帳本"'; sleep 6
must 'button "分享邀請"' '建立後停在分享關（邀請碼＋分享鈕）'
click_ref 'button "開始使用"'; sleep 5

must '記帳入口 1/12' '導覽自動開場（步 1）'
click_ref 'button "下一步"'; sleep 2
must '點「預算」 2/12' '步 2：互動步（點預算）'
# 亮區以外全鎖：點「統計」不應換頁
click_ref 'tab "統計"' || true; sleep 2
must '點「預算」 2/12' '步 2：鎖區點擊被擋'
click_ref 'tab "預算"'; sleep 3
must '信封預算 3/12' '步 3：進預算頁'
click_ref 'button "下一步"'; sleep 2
click_ref 'tab "清單"'; sleep 3
must '試試新增購物項目 5/12' '步 5：清單頁'
click_ref 'button "新增購物項目"'; sleep 3
must '購物清單 6/12' '步 6：點＋開了 sheet'
must 'textbox' '新增購物 sheet 真的開著（有輸入欄）'
# semantics（無障礙樹）對 modal 以外的節點一律 inert：e2e 按不到教學卡的「下一步」，
# 真手指走 pointer 路徑沒這限制（widget test 覆蓋）。e2e 改用 Escape 關 sheet 再前進。
PW press Escape >/dev/null; sleep 2
click_ref 'button "下一步"'; sleep 2
must '回「帳目」 7/12' '步 7：sheet 已收、要回帳目'
click_ref 'tab "帳目"'; sleep 3
must '家庭與個人 8/12' '步 8：視角說明'
click_ref 'button "下一步"'; sleep 2
must '點齒輪 9/12' '步 9：互動步（齒輪）'
click_ref 'button "設定"'; sleep 3
must '點「分類管理」 10/12' '步 10：設定頁'
click_ref 'button "分類管理'; sleep 3
must '分類管理 11/12' '步 11：分類頁說明'
click_ref 'button "下一步"'; sleep 2
must '準備好了！ 12/12' '步 12：完成頁'
click_ref 'button "開始使用"'; sleep 3
must 'button "新增"' '導覽收掉、回帳目頁（FAB 可見）'
if PW snapshot 2>/dev/null | grep -q '跳過'; then echo 'FAIL: overlay 沒收乾淨'; exit 1; fi
echo '=== 新手教學 e2e 全部通過 ==='
