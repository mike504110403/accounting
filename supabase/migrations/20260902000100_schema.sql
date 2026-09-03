-- Migration 0001 — schema（依 docs/specs/ledger.md「領域模型」）
-- 幣別台幣整數元；分攤額 numeric(12,2)；結算淨額四捨五入整數（ADR-0005）。

-- Supabase 慣例：擴充放 extensions schema，public 只放應用物件。
create extension if not exists pg_trgm with schema extensions;

-- 保險：如果這個環境早就在別的 schema 裝過 pg_trgm（例如有人在雲端 dashboard 點過安裝），
-- 上面那行是 no-op，底下的索引就會找不到 extensions.gin_trgm_ops。搬過去。
do $$
begin
  if exists (
    select 1 from pg_extension e
    join pg_namespace n on n.oid = e.extnamespace
    where e.extname = 'pg_trgm' and n.nspname <> 'extensions'
  ) then
    alter extension pg_trgm set schema extensions;
  end if;
end;
$$;

-- ---------- enums ----------
create type public.entry_kind as enum ('expense', 'income');
create type public.entry_scope as enum ('private', 'shared');
create type public.split_method as enum ('equal', 'ratio', 'amount', 'common');
create type public.settled_state as enum ('open', 'settling', 'settled');
create type public.settlement_status as enum ('pending', 'settled', 'void');

-- ---------- 邀請碼 ----------
-- 6 碼大寫英數，去掉易混淆字元（0/O/1/I）。
create or replace function public.gen_invite_code()
returns text
language plpgsql
volatile
set search_path = public
as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code text;
  v_i int;
begin
  loop
    v_code := '';
    for v_i in 1..6 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.ledgers l where l.invite_code = v_code);
  end loop;
  return v_code;
end;
$$;

-- ---------- 表 ----------
create table public.ledgers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) > 0),
  invite_code text not null unique default public.gen_invite_code() check (invite_code ~ '^[A-Z0-9]{6}$'),
  -- member_id(text) → 百分比(int)，合計 100。
  default_ratio jsonb not null default '{}'::jsonb,
  opening_balance_shared int not null default 0,
  created_at timestamptz not null default now()
);

create table public.members (
  id uuid primary key default gen_random_uuid(),
  ledger_id uuid not null references public.ledgers (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  display_name text not null,
  opening_balance_personal int not null default 0,
  joined_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (ledger_id, user_id)
);
create index members_user_id_idx on public.members (user_id);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  ledger_id uuid not null references public.ledgers (id) on delete cascade,
  kind public.entry_kind not null,
  name text not null check (length(btrim(name)) > 0),
  icon text not null default 'more_horiz',
  sort int not null default 0,
  rollover boolean not null default false,
  created_at timestamptz not null default now()
);
create index categories_ledger_idx on public.categories (ledger_id, kind, sort);

create table public.entries (
  id uuid primary key default gen_random_uuid(),
  ledger_id uuid not null references public.ledgers (id) on delete cascade,
  kind public.entry_kind not null,
  scope public.entry_scope not null default 'shared',
  -- 整數元；修正筆（is_adjustment）才可為負。
  amount int not null,
  category_id uuid not null references public.categories (id) on delete restrict,
  occurred_on date not null,
  note text not null default '',
  created_by uuid not null references public.members (id) on delete restrict,
  -- null ＝ 共同錢包。
  payer_id uuid references public.members (id) on delete restrict,
  split_method public.split_method not null default 'common',
  settled_state public.settled_state not null default 'open',
  is_adjustment boolean not null default false,
  created_at timestamptz not null default now(),
  constraint entries_amount_sign check (is_adjustment or amount >= 0),
  -- ADR-0003：私人筆 payer 固定本人，不參與分攤結算。
  constraint entries_private_payer check (scope <> 'private' or payer_id = created_by),
  constraint entries_private_no_split check (scope <> 'private' or split_method = 'common'),
  constraint entries_private_open check (scope <> 'private' or settled_state = 'open')
);
create index entries_ledger_occurred_idx on public.entries (ledger_id, occurred_on);
create index entries_note_trgm_idx on public.entries using gin (note extensions.gin_trgm_ops);
create index entries_settle_idx on public.entries (ledger_id, settled_state);

create table public.entry_splits (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.entries (id) on delete cascade,
  member_id uuid not null references public.members (id) on delete cascade,
  share numeric(12, 2) not null,
  created_at timestamptz not null default now(),
  unique (entry_id, member_id)
);
create index entry_splits_entry_idx on public.entry_splits (entry_id);
create index entry_splits_member_idx on public.entry_splits (member_id);

create table public.line_items (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.entries (id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  -- 可空；加總可不等於主筆金額（ADR-0001）。
  amount int,
  sort int not null default 0,
  created_at timestamptz not null default now()
);
create index line_items_entry_idx on public.line_items (entry_id);
create index line_items_name_trgm_idx on public.line_items using gin (name extensions.gin_trgm_ops);

create table public.settlements (
  id uuid primary key default gen_random_uuid(),
  ledger_id uuid not null references public.ledgers (id) on delete cascade,
  status public.settlement_status not null default 'pending',
  initiated_by uuid not null references public.members (id) on delete restrict,
  -- member_id(text) → 淨額(int)，正＝應收、負＝應付。
  nets jsonb not null default '{}'::jsonb,
  settled_at timestamptz,
  created_at timestamptz not null default now()
);
create index settlements_ledger_status_idx on public.settlements (ledger_id, status);

create table public.settlement_entries (
  id uuid primary key default gen_random_uuid(),
  settlement_id uuid not null references public.settlements (id) on delete cascade,
  entry_id uuid not null references public.entries (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (settlement_id, entry_id)
);
create index settlement_entries_entry_idx on public.settlement_entries (entry_id);

create table public.settlement_approvals (
  id uuid primary key default gen_random_uuid(),
  settlement_id uuid not null references public.settlements (id) on delete cascade,
  member_id uuid not null references public.members (id) on delete cascade,
  approved_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (settlement_id, member_id)
);

create table public.budgets (
  id uuid primary key default gen_random_uuid(),
  ledger_id uuid not null references public.ledgers (id) on delete cascade,
  category_id uuid not null references public.categories (id) on delete cascade,
  -- 該月 1 號（自然月，ADR-0004）。
  month date not null check (extract(day from month) = 1),
  -- 基礎上限；「limit」是 SQL 保留字，欄名用 limit_amount。
  limit_amount int not null check (limit_amount >= 0),
  created_at timestamptz not null default now(),
  unique (ledger_id, category_id, month)
);

create table public.list_items (
  id uuid primary key default gen_random_uuid(),
  ledger_id uuid not null references public.ledgers (id) on delete cascade,
  title text not null check (length(btrim(title)) > 0),
  store text,
  estimated int,
  -- null ＝ 待辦（非購物項目）。
  category_id uuid references public.categories (id) on delete set null,
  assignee_id uuid references public.members (id) on delete set null,
  due_on date,
  done_at timestamptz,
  -- 勾選後產生的支出。
  entry_id uuid references public.entries (id) on delete set null,
  sort int not null default 0,
  created_at timestamptz not null default now()
);
create index list_items_ledger_idx on public.list_items (ledger_id, done_at);
create index list_items_title_trgm_idx on public.list_items using gin (title extensions.gin_trgm_ops);
