-- Migration 0014 — 跨帳本 FK（review 18）
--
-- 原本 category_id／member_id 只 FK 到主鍵，不保證跟本列是同一本帳：
-- 成員可以把自己帳本的支出掛到別人帳本的分類、或把別人帳本的成員設成付款人。
-- 修法：被參照表加 unique (id, ledger_id)，參照方改用複合 FK 綁住 ledger_id。
-- 單欄 FK 保留不動（複合 FK 比較嚴，兩者並存不衝突，也就不需要 drop）。

-- F：先盤點跨帳本的既有髒資料，有的話用看得懂的訊息停下來
--     （否則 push 只會看到一句 "violates foreign key constraint"，看不出是哪一類）。
do $$
declare
  v_report text := '';
  v_n bigint;
begin
  select count(*) into v_n from public.entries e
   where not exists (select 1 from public.categories c where c.id = e.category_id and c.ledger_id = e.ledger_id);
  if v_n > 0 then v_report := v_report || format('entries 有 %s 筆的分類不屬於同一帳本；', v_n); end if;

  select count(*) into v_n from public.entries e
   where not exists (select 1 from public.members m where m.id = e.created_by and m.ledger_id = e.ledger_id);
  if v_n > 0 then v_report := v_report || format('entries 有 %s 筆的 created_by 不屬於同一帳本；', v_n); end if;

  select count(*) into v_n from public.entries e
   where e.payer_id is not null
     and not exists (select 1 from public.members m where m.id = e.payer_id and m.ledger_id = e.ledger_id);
  if v_n > 0 then v_report := v_report || format('entries 有 %s 筆的付款人不屬於同一帳本；', v_n); end if;

  select count(*) into v_n from public.budgets b
   where not exists (select 1 from public.categories c where c.id = b.category_id and c.ledger_id = b.ledger_id);
  if v_n > 0 then v_report := v_report || format('budgets 有 %s 筆的分類不屬於同一帳本；', v_n); end if;

  select count(*) into v_n from public.settlements s
   where not exists (select 1 from public.members m where m.id = s.initiated_by and m.ledger_id = s.ledger_id);
  if v_n > 0 then v_report := v_report || format('settlements 有 %s 筆的發起人不屬於同一帳本；', v_n); end if;

  select count(*) into v_n from public.entry_splits es
   join public.entries e on e.id = es.entry_id
   where not exists (select 1 from public.members m where m.id = es.member_id and m.ledger_id = e.ledger_id);
  if v_n > 0 then v_report := v_report || format('entry_splits 有 %s 筆的成員不屬於父 entry 的帳本；', v_n); end if;

  select count(*) into v_n from public.list_items l
   where (l.category_id is not null
          and not exists (select 1 from public.categories c where c.id = l.category_id and c.ledger_id = l.ledger_id))
      or (l.assignee_id is not null
          and not exists (select 1 from public.members m where m.id = l.assignee_id and m.ledger_id = l.ledger_id));
  if v_n > 0 then v_report := v_report || format('list_items 有 %s 筆引用了別的帳本的分類或成員；', v_n); end if;

  select count(*) into v_n from public.list_items l
   where l.entry_id is not null
     and not exists (select 1 from public.entries e where e.id = l.entry_id and e.ledger_id = l.ledger_id);
  if v_n > 0 then v_report := v_report || format('list_items 有 %s 筆的 entry_id 指向別的帳本的帳目；', v_n); end if;

  if v_report <> '' then
    raise exception '無法建立跨帳本 FK：%。請先把這些列改成同帳本的引用（或清掉）再重跑。', v_report;
  end if;
end;
$$;

alter table public.categories add constraint categories_id_ledger_key unique (id, ledger_id);
alter table public.members    add constraint members_id_ledger_key    unique (id, ledger_id);
alter table public.entries    add constraint entries_id_ledger_key    unique (id, ledger_id);

-- entries：分類、記錄人、付款人都必須同帳本。
alter table public.entries
  add constraint entries_category_same_ledger
  foreign key (category_id, ledger_id) references public.categories (id, ledger_id) on delete restrict;
alter table public.entries
  add constraint entries_created_by_same_ledger
  foreign key (created_by, ledger_id) references public.members (id, ledger_id) on delete restrict;
alter table public.entries
  add constraint entries_payer_same_ledger
  foreign key (payer_id, ledger_id) references public.members (id, ledger_id) on delete restrict;

-- budgets：分類同帳本（單欄 FK 是 on delete cascade，複合也用 cascade，行為不變）。
alter table public.budgets
  add constraint budgets_category_same_ledger
  foreign key (category_id, ledger_id) references public.categories (id, ledger_id) on delete cascade;

-- settlements：發起人同帳本。
alter table public.settlements
  add constraint settlements_initiator_same_ledger
  foreign key (initiated_by, ledger_id) references public.members (id, ledger_id) on delete restrict;

-- list_items：category_id／assignee_id 是 on delete set null，
-- 複合 FK 的 set null 會連 ledger_id 一起設 null（NOT NULL）而爆掉，所以改用 check trigger。
create or replace function public.list_items_same_ledger()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if NEW.category_id is not null
     and not exists (select 1 from public.categories c
                     where c.id = NEW.category_id and c.ledger_id = NEW.ledger_id) then
    raise exception 'list_item: category belongs to another ledger' using errcode = 'P0001';
  end if;
  if NEW.assignee_id is not null
     and not exists (select 1 from public.members m
                     where m.id = NEW.assignee_id and m.ledger_id = NEW.ledger_id) then
    raise exception 'list_item: assignee belongs to another ledger' using errcode = 'P0001';
  end if;
  if NEW.entry_id is not null
     and not exists (select 1 from public.entries e
                     where e.id = NEW.entry_id and e.ledger_id = NEW.ledger_id) then
    raise exception 'list_item: entry belongs to another ledger' using errcode = 'P0001';
  end if;
  return NEW;
end;
$$;
revoke execute on function public.list_items_same_ledger() from anon, authenticated, public;

create trigger list_items_same_ledger_trg
  before insert or update of category_id, assignee_id, entry_id, ledger_id on public.list_items
  for each row execute function public.list_items_same_ledger();

-- entry_splits 沒有 ledger_id，改用 check trigger 驗「分攤成員與父 entry 同帳本」。
create or replace function public.entry_splits_same_ledger()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_entry_ledger uuid;
begin
  select e.ledger_id into v_entry_ledger from public.entries e where e.id = NEW.entry_id;
  if v_entry_ledger is null then
    raise exception 'entry_split: entry not found' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.members m
                 where m.id = NEW.member_id and m.ledger_id = v_entry_ledger) then
    raise exception 'entry_split: member belongs to another ledger' using errcode = 'P0001';
  end if;
  return NEW;
end;
$$;
revoke execute on function public.entry_splits_same_ledger() from anon, authenticated, public;

create trigger entry_splits_same_ledger_trg
  before insert or update of member_id, entry_id on public.entry_splits
  for each row execute function public.entry_splits_same_ledger();
