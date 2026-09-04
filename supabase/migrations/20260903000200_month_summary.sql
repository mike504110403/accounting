-- 月摘要 RPC（Mike 裁示 2026-09-03：畫面上的衍生數字由 DB 依 Supabase 資料計算，
-- 客戶端不自己算完直接顯示）。語義逐條對齊前端 balance_math.dart（spec v1.3／ADR-0007）：
--   shared_balance   ＝ 期初共同 ＋ Σ共同收入 − Σ共同錢包支出（payer_id is null；代墊不動共同餘額）
--   分類信封（只看 p_until 所在月）：allocated＝Σ撥款（同月且 ≤ p_until）；
--     spent＝Σ funding='budget' 的共同錢包支出（同月且 ≤ p_until）；
--     remaining＝max(0, allocated−spent)；over＝max(0, spent−allocated)
--   envelope_total／overspend_total＝跨分類合計；shared_available＝shared_balance−envelope_total
--   me.personal_balance（只算呼叫者自己；security invoker，讀不到別人的私人筆）＝
--     期初個人 ＋ Σ本人私人收支 − Σ本人代墊全額 ＋ Σ已 settled 結算的 nets[本人]
-- 注意：settled_at 是 timestamptz，這裡取 UTC 日期截斷比對（前端 _upTo 用本地日期，
-- 邊界日（結算當天午夜附近）可能差一天；記帳場景可接受，變更請連前端一起改）。

create or replace function public.month_summary(p_ledger uuid, p_until date)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
with me as (
  select id from members where ledger_id = p_ledger and user_id = auth.uid()
),
sb as (
  select (select opening_balance_shared from ledgers where id = p_ledger)
       + coalesce(sum(case
           when kind = 'income' then amount
           when payer_id is null then -amount
           else 0 end), 0) as shared_balance
  from entries
  where ledger_id = p_ledger and scope = 'shared' and occurred_on <= p_until
),
alloc as (
  select category_id, sum(amount)::int as allocated
  from budget_allocation
  where ledger_id = p_ledger
    and date_trunc('month', occurred_on) = date_trunc('month', p_until)
    and occurred_on <= p_until
  group by category_id
),
spent as (
  select category_id, sum(amount)::int as spent
  from entries
  where ledger_id = p_ledger and kind = 'expense' and scope = 'shared'
    and payer_id is null and funding = 'budget'
    and date_trunc('month', occurred_on) = date_trunc('month', p_until)
    and occurred_on <= p_until
  group by category_id
),
env as (
  select coalesce(a.category_id, s.category_id) as category_id,
         coalesce(a.allocated, 0) as allocated,
         coalesce(s.spent, 0) as spent,
         greatest(0, coalesce(a.allocated, 0) - coalesce(s.spent, 0)) as remaining,
         greatest(0, coalesce(s.spent, 0) - coalesce(a.allocated, 0)) as over
  from alloc a
  full outer join spent s using (category_id)
),
pb as (
  select m.id as member_id,
         m.opening_balance_personal
       + coalesce((select sum(case when e.kind = 'income' then e.amount else -e.amount end)
                   from entries e
                   where e.ledger_id = p_ledger and e.scope = 'private'
                     and e.created_by = m.id and e.occurred_on <= p_until), 0)
       - coalesce((select sum(e.amount)
                   from entries e
                   where e.ledger_id = p_ledger and e.scope = 'shared' and e.kind = 'expense'
                     and e.payer_id = m.id and e.occurred_on <= p_until), 0)
       + coalesce((select sum((s.nets ->> m.id::text)::int)
                   from settlements s
                   where s.ledger_id = p_ledger and s.status = 'settled'
                     and s.settled_at is not null
                     and (s.settled_at at time zone 'utc')::date <= p_until), 0)
         as personal_balance
  from members m
  where m.ledger_id = p_ledger and m.id in (select id from me)
)
select jsonb_build_object(
  'shared_balance', (select shared_balance from sb),
  'envelope_total', coalesce((select sum(remaining) from env), 0),
  'overspend_total', coalesce((select sum(over) from env), 0),
  'shared_available',
    (select shared_balance from sb) - coalesce((select sum(remaining) from env), 0),
  'categories', coalesce(
    (select jsonb_agg(jsonb_build_object(
        'category_id', category_id,
        'allocated', allocated,
        'spent', spent,
        'remaining', remaining,
        'over', over) order by category_id)
     from env), '[]'::jsonb),
  'me', (select jsonb_build_object(
      'member_id', member_id,
      'personal_balance', personal_balance)
     from pb)
);
$$;

-- 慣例（20260902001100 起）：函式 ACL 白名單——public/anon 全收回、只留 authenticated。
revoke all on function public.month_summary(uuid, date) from public, anon;
grant execute on function public.month_summary(uuid, date) to authenticated;
