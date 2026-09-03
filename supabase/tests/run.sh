#!/usr/bin/env bash
# 一鍵跑 DB 測試：db reset（migrations + seed）後逐檔 psql，任何 assert 失敗即非零退出。
#   用法：supabase/tests/run.sh [--no-reset]
#
# --no-reset 只在「剛剛才 reset 過」的資料庫上有效。
# 測試全部包在 begin/rollback 裡，但 supabase db reset 之外的任何寫入（手動改資料、
# 另一個 worktree 動過同一個地端棧）都會讓計數型斷言失敗。不確定就不要帶這個旗標。
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cd "$root"

SUPABASE_BIN="${SUPABASE_BIN:-$HOME/.local/bin/supabase}"
DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"

# psql：先看 PATH，再看 homebrew libpq。
PSQL="${PSQL:-}"
if [ -z "$PSQL" ]; then
  if command -v psql >/dev/null 2>&1; then
    PSQL="$(command -v psql)"
  elif [ -x /opt/homebrew/opt/libpq/bin/psql ]; then
    PSQL=/opt/homebrew/opt/libpq/bin/psql
  elif [ -x /usr/local/opt/libpq/bin/psql ]; then
    PSQL=/usr/local/opt/libpq/bin/psql
  else
    echo "找不到 psql，請設 PSQL=<路徑> 或安裝 libpq" >&2
    exit 1
  fi
fi

do_reset=1
case "${1:-}" in
  "")          do_reset=1 ;;
  --no-reset)  do_reset=0 ;;
  *)
    echo "未知參數：$1" >&2
    echo "用法：supabase/tests/run.sh [--no-reset]" >&2
    exit 2
    ;;
esac
if [ "$#" -gt 1 ]; then
  echo "參數過多：$*" >&2
  echo "用法：supabase/tests/run.sh [--no-reset]" >&2
  exit 2
fi

# 地端棧的兩個坑（都實際踩過，別把這段拿掉）：
#  1. db reset 尾端會 Restarting containers，指令回來時 Postgres 還沒開始收連線，
#     直接跑 psql 會是 "Connection refused"／"server closed the connection unexpectedly"。
#  2. 連續兩次 db reset 之間若棧還沒穩定，CLI 會回 LegacyDbSetupError，
#     或是回報「migration 都套用了」但 psql 連過去卻是空的 schema
#     （測試就會變成一連串看不懂的 "type public.settlements does not exist"）。
# 所以：reset 前後都等連線，reset 後再驗一次 schema 真的在，不在就重試一次才放棄。

# 等到 psql 連得上（最多 90 秒）
wait_for_db() {
  local i
  for i in $(seq 1 90); do
    if "$PSQL" "$DB_URL" -q -t -c 'select 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "等了 90 秒資料庫仍未就緒：$DB_URL" >&2
  return 1
}

# migration 是否真的落在這個連線看得到的資料庫上
schema_ready() {
  local n
  n="$("$PSQL" "$DB_URL" -q -t -A -c \
    "select count(*) from pg_class c join pg_namespace ns on ns.oid = c.relnamespace \
      where ns.nspname = 'public' and c.relname in ('settlements','entries','settlement_signers')" \
    2>/dev/null || echo 0)"
  [ "$n" = "3" ]
}

# 種子是不是「剛 reset 完」的原始狀態。
# 只驗表存在是不夠的：實際踩過 reset 之後連過去卻是上一輪跑剩的資料，
# 筆數對得上（測試都 rollback）但個別欄位被改過，於是測試在中段莫名其妙爆掉。
# 這裡驗三件事：帳目筆數、沒有殘留的結算、每筆分攤加總與主筆金額相符。
seed_ready() {
  local out
  out="$("$PSQL" "$DB_URL" -q -t -A -F',' -c \
    "select (select count(*) from public.entries),
            (select count(*) from public.settlements),
            (select count(*) from public.entries e
              where e.split_method <> 'common' and e.scope <> 'private'
                and exists (select 1 from public.entry_splits s where s.entry_id = e.id)
                and abs((select sum(s.share) from public.entry_splits s where s.entry_id = e.id) - e.amount) >= 0.01)" \
    2>/dev/null || echo "x")"
  if [ "$out" != "10,0,0" ]; then
    echo "  種子狀態不對（entries,settlements,分攤不符筆數 = $out，預期 10,0,0）" >&2
    return 1
  fi
  return 0
}

reset_db() {
  echo "== supabase db reset =="
  "$SUPABASE_BIN" db reset
  echo "== 等待資料庫就緒 =="
  wait_for_db
}

if [ "$do_reset" -eq 1 ]; then
  # 先確定棧是穩的再動手，避免踩到坑 2。
  wait_for_db || true
  reset_db
  if ! schema_ready || ! seed_ready; then
    echo "reset 後 schema／種子不對（地端棧沒穩定），重試一次…" >&2
    sleep 5
    reset_db
  fi
else
  wait_for_db
fi

if ! schema_ready; then
  echo "資料庫裡找不到預期的 schema，測試不跑（避免產生一堆看不懂的錯誤）。" >&2
  echo "請先確認地端棧狀態：~/.local/bin/supabase status" >&2
  exit 1
fi
if ! seed_ready; then
  echo "資料庫不是乾淨的種子狀態，測試不跑。" >&2
  if [ "$do_reset" -eq 0 ]; then
    echo "（你用了 --no-reset；這個旗標只在剛 reset 過的資料庫上有效）" >&2
  fi
  exit 1
fi

status=0
for f in "$here"/*.sql; do
  echo
  echo "== $(basename "$f") =="
  if ! "$PSQL" "$DB_URL" -v ON_ERROR_STOP=1 -q -f "$f"; then
    echo "FAIL: $(basename "$f")" >&2
    status=1
  fi
done

echo
if [ "$status" -eq 0 ]; then
  echo "ALL SQL TESTS PASSED"
else
  echo "SQL TESTS FAILED" >&2
fi
exit "$status"
