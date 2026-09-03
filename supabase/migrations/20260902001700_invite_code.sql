-- Migration 0017 — 邀請碼加長與撞碼重試（review 19／22）
--
-- 6 碼 base32 ≈ 10 億組，對「猜邀請碼硬闖帳本」來說太薄。改 10 碼（≈ 1.1e15 組），
-- 亂數改用 extensions.gen_random_bytes（CSPRNG），不用 random()。
-- 註：check constraint 沒辦法改內容，只能 drop 再 add——這是本 repo 唯一一處 drop，
-- 且不涉及資料（constraint 而非欄位）。

create or replace function public.gen_invite_code()
returns text
language plpgsql
volatile
set search_path = public
as $$
declare
  -- base32，去掉易混淆的 0/O/1/I；256 是 32 的整數倍，取模不偏。
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes bytea;
  v_code text;
  v_i int;
begin
  loop
    v_code := '';
    v_bytes := extensions.gen_random_bytes(10);
    for v_i in 0..9 loop
      v_code := v_code || substr(v_alphabet, 1 + (get_byte(v_bytes, v_i) % 32), 1);
    end loop;
    exit when not exists (select 1 from public.ledgers l where l.invite_code = v_code);
  end loop;
  return v_code;
end;
$$;
revoke execute on function public.gen_invite_code() from anon, authenticated, public;

-- G：gen_random_bytes／crypt 來自 pgcrypto，這裡把隱性依賴寫明（Supabase 預設已裝）。
create extension if not exists pgcrypto with schema extensions;

-- F/P：順序是 drop → backfill → add，三步都不能調換。
-- 先 backfill 再 drop 的話，UPDATE 寫進去的 10 碼會被「還沒拿掉的舊 6 碼 check」擋下來，
-- 對已有資料的環境套這支必炸（地端種子表在此刻是空的，所以測不出來）。
alter table public.ledgers drop constraint if exists ledgers_invite_code_check;

update public.ledgers set invite_code = public.gen_invite_code()
 where invite_code !~ '^[A-Z0-9]{10}$';

alter table public.ledgers add constraint ledgers_invite_code_check
  check (invite_code ~ '^[A-Z0-9]{10}$');



-- 22：上面的 not exists 只是先篩，真正的競態要靠 unique 索引 ＋ 重試。
create or replace function public.create_ledger(name text)
returns public.ledgers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_ledger public.ledgers;
  v_member public.members;
  v_display text;
  v_try int := 0;
begin
  if v_uid is null then
    raise exception 'create_ledger: not authenticated' using errcode = '28000';
  end if;
  if name is null or btrim(name) = '' then
    raise exception 'create_ledger: name required' using errcode = 'P0001';
  end if;

  select coalesce(
           nullif(btrim(u.raw_user_meta_data ->> 'full_name'), ''),
           nullif(split_part(u.email, '@', 1), ''),
           '我'
         )
    into v_display
  from auth.users u
  where u.id = v_uid;

  -- 邀請碼撞 unique 就重抽（10 碼下幾乎不會發生，但併發時不該讓使用者看到 500）。
  loop
    v_try := v_try + 1;
    begin
      insert into public.ledgers (name) values (btrim(name)) returning * into v_ledger;
      exit;
    exception when unique_violation then
      if v_try >= 5 then
        raise exception 'create_ledger: could not allocate an invite code' using errcode = 'P0001';
      end if;
    end;
  end loop;

  insert into public.members (ledger_id, user_id, display_name)
  values (v_ledger.id, v_uid, coalesce(v_display, '我'))
  returning * into v_member;

  update public.ledgers
    set default_ratio = jsonb_build_object(v_member.id::text, 100)
    where id = v_ledger.id
    returning * into v_ledger;

  insert into public.categories (ledger_id, kind, name, icon, sort) values
    (v_ledger.id, 'expense', '食品',     'restaurant',     0),
    (v_ledger.id, 'expense', '餐飲',     'local_dining',   1),
    (v_ledger.id, 'expense', '日常用品', 'inventory_2',    2),
    (v_ledger.id, 'expense', '住房',     'home',           3),
    (v_ledger.id, 'expense', '水電',     'bolt',           4),
    (v_ledger.id, 'expense', '交通',     'directions_car', 5),
    (v_ledger.id, 'expense', '娛樂',     'sports_esports', 6),
    (v_ledger.id, 'income',  '薪水',     'payments',       0),
    (v_ledger.id, 'income',  '獎金',     'card_giftcard',  1);

  return v_ledger;
end;
$$;
revoke execute on function public.create_ledger(text) from anon, public;
grant execute on function public.create_ledger(text) to authenticated;
