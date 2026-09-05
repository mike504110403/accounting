-- 建帳本 / 加入帳本 RPC 測試（v1.5：不再寫 default_ratio）。
\set MIKE '11111111-1111-1111-1111-111111111111'
\set WIFE '22222222-2222-2222-2222-222222222222'

\echo '== rpc: create_ledger 建帳本＋自己成為成員＋預設分類 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l public.ledgers;
  v_m public.members;
begin
  v_l := public.create_ledger('第二本帳');
  assert v_l.name = '第二本帳', '帳本名不對';
  assert v_l.invite_code ~ '^[A-Z0-9]{10}$', format('邀請碼格式不對：%s', v_l.invite_code);

  select * into v_m from public.members m where m.ledger_id = v_l.id;
  assert v_m.user_id = '11111111-1111-1111-1111-111111111111'::uuid, '建帳本的人沒被加成成員';
  assert v_m.display_name = 'Mike', format('display_name 應取 raw_user_meta_data.full_name，實際 %s', v_m.display_name);
  -- v1.5：ledgers 只剩 id／name／invite_code／created_at（default_ratio、opening_balance_shared 已 drop）。
  assert not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'ledgers'
                       and column_name in ('default_ratio', 'opening_balance_shared')),
    'ledgers 不該再有 default_ratio／opening_balance_shared（ADR-0009）';
  assert (select count(*) from public.categories c where c.ledger_id = v_l.id) = 9, '預設分類應有 9 個';
  assert (select count(*) from public.categories c where c.ledger_id = v_l.id and c.kind = 'income') = 2, '預設收入分類應有 2 個';
  -- 建立者看得到新帳本（RLS）。
  assert (select count(*) from public.ledgers) = 2, '建完應看得到兩本帳';
end;
$$;
rollback;

\echo '== rpc: join_ledger 以邀請碼加入、重複加入直接回、錯碼應失敗 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l public.ledgers;
begin
  v_l := public.create_ledger('Mike 的私房帳');
  perform set_config('app.test_invite', v_l.invite_code, true);
end;
$$;

reset role;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l public.ledgers;
  v_code text := current_setting('app.test_invite', true);
  v_blocked boolean := false;
  v_err text;
begin
  -- 應失敗①：亂碼加不進去。
  begin
    perform public.join_ledger('ZZZZZZ');
  exception when others then
    v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '錯的邀請碼竟然加得進去';
  raise notice '  預期的失敗：%', v_err;

  v_l := public.join_ledger(v_code);
  assert (select count(*) from public.members m where m.ledger_id = v_l.id) = 2, '加入後應有兩位成員';
  -- v1.5 沒有分攤比例，join_ledger 只負責把人加進來。
  assert (select count(*) from public.members m
           where m.ledger_id = v_l.id and m.user_id = '22222222-2222-2222-2222-222222222222') = 1,
    '加入者應該有一列 member';

  -- 已是成員 → 直接回，不重複插入。
  v_l := public.join_ledger(v_code);
  assert (select count(*) from public.members m where m.ledger_id = v_l.id) = 2, '重複加入不該多一位成員';
end;
$$;
rollback;

\echo '== rpc: 小寫邀請碼也吃得到 =='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'WIFE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_l public.ledgers;
begin
  -- 種子帳本的邀請碼是 A7K3QZM4XB，老婆已是成員 → 直接回同一本。
  v_l := public.join_ledger(' a7k3qzm4xb ');
  assert v_l.id = '10000000-0000-0000-0000-000000000001'::uuid, '小寫／含空白的邀請碼應正規化後比對';
end;
$$;
rollback;

\echo 'rpc.sql PASS'
