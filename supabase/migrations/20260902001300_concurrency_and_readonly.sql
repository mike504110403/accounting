-- Migration 0013 — 併發競態、刪除 policy、寫入面再收斂（review 13／15／16／17，併 7）

-- ---------- 13：同一帳本同時只能有一個 pending 結算 ----------
-- 兩層：partial unique index（資料層保證）＋ advisory lock（避免兩邊都做完白工才撞索引）。
-- F：先盤點，有違規列就用看得懂的訊息停下來（否則 push 只會看到 unique index 建立失敗）。
do $$
declare
  v_bad text;
begin
  select string_agg(format('ledger %s 有 %s 筆 pending', t.ledger_id, t.n), '；')
    into v_bad
  from (select ledger_id, count(*) as n from public.settlements
         where status = 'pending' group by ledger_id having count(*) > 1) t;
  if v_bad is not null then
    raise exception '無法建立「一帳本一 pending 結算」的唯一索引：%。請先把多餘的 pending settlement 改成 void 再重跑。', v_bad;
  end if;
end;
$$;

create unique index settlements_one_pending_per_ledger_idx
  on public.settlements (ledger_id)
  where status = 'pending';

-- ---------- 15：settled 不可刪，policy 與 before trigger 雙保險 ----------
alter policy entries_delete on public.entries
  using (
    public.is_member(ledger_id)
    and (scope = 'shared' or created_by = public.my_member_id(ledger_id))
    and settled_state <> 'settled'
  );

alter policy entry_splits_delete on public.entry_splits
  using (exists (
    select 1 from public.entries e
    where e.id = entry_id
      and public.is_member(e.ledger_id)
      and (e.scope = 'shared' or e.created_by = public.my_member_id(e.ledger_id))
      and e.settled_state <> 'settled'
  ));

-- ---------- 16：settlement_entries 的 entry 必須與 settlement 同帳本 ----------
create or replace function public.settlement_entries_same_ledger()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_settlement_ledger uuid;
  v_entry_ledger uuid;
begin
  select s.ledger_id into v_settlement_ledger from public.settlements s where s.id = NEW.settlement_id;
  select e.ledger_id into v_entry_ledger from public.entries e where e.id = NEW.entry_id;
  if v_settlement_ledger is null or v_entry_ledger is null then
    raise exception 'settlement_entries: settlement or entry not found' using errcode = 'P0001';
  end if;
  if v_settlement_ledger <> v_entry_ledger then
    raise exception 'settlement_entries: entry belongs to another ledger' using errcode = 'P0001';
  end if;
  return NEW;
end;
$$;
revoke execute on function public.settlement_entries_same_ledger() from anon, authenticated, public;

create trigger settlement_entries_same_ledger_trg
  before insert or update on public.settlement_entries
  for each row execute function public.settlement_entries_same_ledger();

-- ---------- 17：簽名也收回前端，只走 approve_settlement ----------
revoke insert on public.settlement_approvals from authenticated;
drop policy if exists settlement_approvals_insert on public.settlement_approvals;

-- ---------- 17：members 只能改自己那列，且不得換帳本／換人 ----------
alter policy members_update on public.members
  using (user_id = auth.uid() and public.is_member(ledger_id))
  with check (user_id = auth.uid() and public.is_member(ledger_id));

create or replace function public.members_immutable_identity()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if NEW.ledger_id is distinct from OLD.ledger_id then
    raise exception 'member: ledger_id is immutable' using errcode = 'P0001';
  end if;
  if NEW.user_id is distinct from OLD.user_id then
    raise exception 'member: user_id is immutable' using errcode = 'P0001';
  end if;
  return NEW;
end;
$$;
revoke execute on function public.members_immutable_identity() from anon, authenticated, public;

create trigger members_immutable_identity_trg
  before update of ledger_id, user_id on public.members
  for each row execute function public.members_immutable_identity();

-- ---------- 7（追加）：void_settlements_for_entry 只准 trigger 內部呼叫 ----------
create or replace function public.void_settlements_for_entry(p_entry uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settlement uuid;
begin
  if pg_trigger_depth() = 0 then
    raise exception 'void_settlements_for_entry: internal only, call cancel_settlement instead'
      using errcode = '42501';
  end if;
  for v_settlement in
    select se.settlement_id
    from public.settlement_entries se
    join public.settlements s on s.id = se.settlement_id
    where se.entry_id = p_entry and s.status = 'pending'
  loop
    update public.settlements set status = 'void' where id = v_settlement;
    update public.entries
      set settled_state = 'open'
      where settled_state = 'settling'
        and id in (select entry_id from public.settlement_entries where settlement_id = v_settlement);
  end loop;
end;
$$;
revoke execute on function public.void_settlements_for_entry(uuid) from anon, authenticated, public;

-- ---------- 22：entries.category_id 索引（category 是 on delete restrict，沒索引會全表掃） ----------
create index entries_category_idx on public.entries (category_id);
