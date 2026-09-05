-- 結構完整性測試：跨帳本 FK、entries 的 check、upsert_entry 子表語意、索引與邀請碼。
-- 這一檔多數以 postgres 身分跑：要驗的是「即使繞過 RLS，資料層本身也擋得住」。
-- v1.5（ADR-0009）：分攤守恆、結算唯一性那幾條隨 entry_splits／settlements 一起消失。
\set MIKE '11111111-1111-1111-1111-111111111111'
\set WIFE '22222222-2222-2222-2222-222222222222'
\set MIKE_M '20000000-0000-0000-0000-000000000001'
\set WIFE_M '20000000-0000-0000-0000-000000000002'
\set LEDGER '10000000-0000-0000-0000-000000000001'
\set CAT '30000000-0000-0000-0000-000000000001'

\echo '== integrity: 結構前置檢查（索引、唯一鍵）=='
do $$
begin
  -- review 22：category_id 是 on delete restrict，沒索引刪分類會全表掃。
  assert exists (select 1 from pg_index x
                 join pg_class i on i.oid = x.indexrelid
                 join pg_class t on t.oid = x.indrelid
                 join pg_attribute a on a.attrelid = t.oid and a.attnum = x.indkey[0]
                 where t.relname = 'entries' and a.attname = 'category_id'),
    'entries.category_id 缺索引';
  -- review 18：複合 FK 的被參照唯一鍵。
  assert (select count(*) from pg_constraint
          where conname in ('categories_id_ledger_key', 'members_id_ledger_key', 'entries_id_ledger_key')) = 3,
    '缺少 (id, ledger_id) 唯一鍵';
  -- v1.5：entries 只剩這些欄位（多一欄少一欄都要在這裡看得見）。
  assert (select string_agg(c.column_name, ', ' order by c.ordinal_position)
          from information_schema.columns c
          where c.table_schema = 'public' and c.table_name = 'entries')
         = 'id, ledger_id, kind, amount, category_id, occurred_on, note, created_by, payer_id, is_adjustment, created_at',
    format('entries 的欄位清單不對：%s',
           (select string_agg(c.column_name, ', ' order by c.ordinal_position)
            from information_schema.columns c
            where c.table_schema = 'public' and c.table_name = 'entries'));
end;
$$;

\echo '== integrity: entries_income_no_payer——收入不得有付款人（應失敗）=='
begin;
do $$
declare
  v_blocked boolean := false;
  v_err text;
  v_state text;
begin
  -- 以 postgres 身分跑：連繞過 RLS 與欄位授權都要被 check 擋住。
  begin
    insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, note, created_by, payer_id)
    values ('10000000-0000-0000-0000-000000000001', 'income', 5000,
            '30000000-0000-0000-0000-000000000008', current_date, '有付款人的收入',
            '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm; v_state := sqlstate;
  end;
  assert v_blocked, '收入竟然帶得了付款人';
  assert v_state = '23514', format('應是 check violation 23514，實際 %s', v_state);
  assert v_err like '%entries_income_no_payer%',
    format('錯誤訊息應點名 entries_income_no_payer，實際：%s', v_err);
  raise notice '  預期的失敗：%', v_err;

  -- 對照組：payer_id 為 null 的收入照常寫得進去；支出帶付款人也照常。
  insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, note, created_by, payer_id)
  values ('10000000-0000-0000-0000-000000000001', 'income', 5000,
          '30000000-0000-0000-0000-000000000008', current_date, '正常收入',
          '20000000-0000-0000-0000-000000000001', null);
  insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, note, created_by, payer_id)
  values ('10000000-0000-0000-0000-000000000001', 'expense', 300,
          '30000000-0000-0000-0000-000000000001', current_date, '正常支出',
          '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001');
end;
$$;
rollback;

\echo '== integrity: entries_amount_sign——只有沖銷筆可以是負數 =='
begin;
do $$
declare
  v_blocked boolean := false;
  v_err text;
begin
  begin
    insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, note, created_by, payer_id)
    values ('10000000-0000-0000-0000-000000000001', 'expense', -100,
            '30000000-0000-0000-0000-000000000001', current_date, '手打負數',
            '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '一般帳目竟然可以是負數';
  assert v_err like '%entries_amount_sign%', format('錯誤訊息不對：%s', v_err);

  -- 沖銷筆可以（spec：沖銷＝金額取負的反向紀錄）。
  insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, note,
                              created_by, payer_id, is_adjustment)
  values ('10000000-0000-0000-0000-000000000001', 'expense', -100,
          '30000000-0000-0000-0000-000000000001', current_date, '沖銷',
          '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', true);
end;
$$;
rollback;

\echo '== integrity: upsert_entry 的舊三參數簽名已不存在（應失敗）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
  v_state text;
begin
  begin
    perform public.upsert_entry(
      jsonb_build_object('ledger_id', '10000000-0000-0000-0000-000000000001',
                         'kind', 'expense', 'amount', 100,
                         'category_id', '30000000-0000-0000-0000-000000000001',
                         'occurred_on', current_date),
      '[]'::jsonb, '[]'::jsonb);
  exception when others then v_blocked := true; v_err := sqlerrm; v_state := sqlstate;
  end;
  assert v_blocked, '帶 p_splits 的三參數 upsert_entry 竟然還在';
  assert v_state = '42883', format('應是 undefined_function 42883，實際 %s：%s', v_state, v_err);
  assert v_err like '%does not exist%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== integrity: upsert_entry 的 null＝不動細項、[]＝清空（review K）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_e public.entries;
begin
  -- e-3「全聯買菜」種子狀態：3 列細項。
  assert (select count(*) from public.line_items li where li.entry_id = '40000000-0000-0000-0000-000000000003') = 3,
    '前置條件：e-3 應有 3 列細項';

  -- 只帶 note、不帶子表 → 細項不該被動到。
  v_e := public.upsert_entry(jsonb_build_object(
    'id', '40000000-0000-0000-0000-000000000003',
    'ledger_id', '10000000-0000-0000-0000-000000000001',
    'note', '只改備註'));
  assert v_e.note = '只改備註', '備註應該有改到';
  assert (select count(*) from public.line_items li where li.entry_id = v_e.id) = 3,
    format('沒帶 p_line_items 就不該動細項，實際剩 %s 列',
           (select count(*) from public.line_items li where li.entry_id = v_e.id));

  -- 明確帶 [] 才是清空。
  v_e := public.upsert_entry(
    jsonb_build_object('id', '40000000-0000-0000-0000-000000000003',
                       'ledger_id', '10000000-0000-0000-0000-000000000001'),
    '[]'::jsonb);
  assert (select count(*) from public.line_items li where li.entry_id = v_e.id) = 0,
    '帶 [] 應該把細項清空';

  -- 有內容 ＝ 全刪重建。
  v_e := public.upsert_entry(
    jsonb_build_object('id', '40000000-0000-0000-0000-000000000003',
                       'ledger_id', '10000000-0000-0000-0000-000000000001'),
    jsonb_build_array(jsonb_build_object('name', '重建', 'amount', 50, 'sort', 0)));
  assert (select count(*) from public.line_items li where li.entry_id = v_e.id) = 1,
    '帶內容應該全刪重建';
end;
$$;
rollback;

\echo '== integrity: upsert_entry 新增一筆帶細項的帳目（付款人與沖銷旗標照寫）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_e public.entries;
begin
  v_e := public.upsert_entry(
    jsonb_build_object(
      'ledger_id', '10000000-0000-0000-0000-000000000001',
      'kind', 'expense', 'amount', 300,
      'category_id', '30000000-0000-0000-0000-000000000001',
      'occurred_on', current_date,
      'note', '新增測試',
      'payer_id', '20000000-0000-0000-0000-000000000001'),
    jsonb_build_array(
      jsonb_build_object('name', '蘋果', 'amount', 100, 'sort', 0),
      jsonb_build_object('name', '香蕉', 'amount', 200, 'sort', 1)));

  assert v_e.id is not null, 'upsert_entry 應回傳新建的帳目';
  assert v_e.created_by = '20000000-0000-0000-0000-000000000001'::uuid,
    'created_by 一律是呼叫者，不吃 p_entry 裡的值';
  assert v_e.payer_id = '20000000-0000-0000-0000-000000000001'::uuid, 'payer_id 應照寫';
  assert v_e.is_adjustment = false, '沒帶 is_adjustment 時預設 false';
  assert (select count(*) from public.line_items li where li.entry_id = v_e.id) = 2, '細項應寫入兩列';

  -- 共同錢包：payer_id 明確給 null。
  v_e := public.upsert_entry(jsonb_build_object(
    'id', v_e.id,
    'ledger_id', '10000000-0000-0000-0000-000000000001',
    'payer_id', ''));
  assert v_e.payer_id is null, 'payer_id 給空字串應該變成共同錢包（null）';
end;
$$;
rollback;

\echo '== integrity: 非成員不能經 upsert_entry 寫別人的帳本（應失敗）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', '33333333-3333-3333-3333-333333333333', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_err text;
  v_state text;
begin
  begin
    perform public.upsert_entry(jsonb_build_object(
      'ledger_id', '10000000-0000-0000-0000-000000000001',
      'kind', 'expense', 'amount', 100,
      'category_id', '30000000-0000-0000-0000-000000000001',
      'occurred_on', current_date));
  exception when others then v_blocked := true; v_err := sqlerrm; v_state := sqlstate;
  end;
  assert v_blocked and v_err = 'upsert_entry: not a member' and v_state = '42501',
    format('訊息不對：%s (%s)', v_err, v_state);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== integrity: 跨帳本引用一律擋（應失敗，review 18）=='
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'MIKE', 'role', 'authenticated')::text, true) as _claims \gset
set local role authenticated;
do $$
declare
  v_other public.ledgers;
begin
  v_other := public.create_ledger('別人的帳本');
  perform set_config('app.other_ledger', v_other.id::text, true);
  perform set_config('app.other_category',
    (select c.id::text from public.categories c where c.ledger_id = v_other.id order by c.sort limit 1), true);
  perform set_config('app.other_member',
    (select m.id::text from public.members m where m.ledger_id = v_other.id limit 1), true);
end;
$$;
reset role;
do $$
declare
  v_other_cat uuid := current_setting('app.other_category', true)::uuid;
  v_other_member uuid := current_setting('app.other_member', true)::uuid;
  v_blocked boolean;
  v_err text;
begin
  -- 應失敗①：拿別的帳本的分類記帳。
  v_blocked := false;
  begin
    insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, note, created_by)
    values ('10000000-0000-0000-0000-000000000001', 'expense', 100,
            v_other_cat, current_date, '跨帳本分類', '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然能用別的帳本的分類記帳';
  raise notice '  預期的失敗：%', v_err;

  -- 應失敗②：拿別的帳本的成員當付款人。
  v_blocked := false;
  begin
    insert into public.entries (ledger_id, kind, amount, category_id, occurred_on, note,
                                created_by, payer_id)
    values ('10000000-0000-0000-0000-000000000001', 'expense', 100,
            '30000000-0000-0000-0000-000000000001', current_date, '跨帳本付款人',
            '20000000-0000-0000-0000-000000000001', v_other_member);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '竟然能用別的帳本的成員當付款人';
  assert v_err like '%entries_payer_same_ledger%', format('錯誤訊息不對：%s', v_err);

  -- 應失敗③：清單項目掛別的帳本的分類。
  v_blocked := false;
  begin
    insert into public.list_items (ledger_id, title, category_id)
    values ('10000000-0000-0000-0000-000000000001', '跨帳本清單', v_other_cat);
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '清單竟然能掛別的帳本的分類';

  -- 應失敗④：撥款掛別的帳本的分類。
  v_blocked := false;
  begin
    insert into public.budget_allocation (ledger_id, category_id, amount, occurred_on, created_by)
    values ('10000000-0000-0000-0000-000000000001', v_other_cat, 100, current_date,
            '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '撥款竟然能掛別的帳本的分類';
  assert v_err like '%budget_allocation_category_same_ledger%', format('錯誤訊息不對：%s', v_err);

  -- 應失敗⑤：補入掛別的帳本的成員。
  v_blocked := false;
  begin
    insert into public.personal_topups (ledger_id, member_id, amount, occurred_on, created_by)
    values ('10000000-0000-0000-0000-000000000001', v_other_member, 100, current_date,
            '20000000-0000-0000-0000-000000000001');
  exception when others then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '補入竟然能掛別的帳本的成員';
  assert v_err like '%personal_topups_member_same_ledger%', format('錯誤訊息不對：%s', v_err);
  raise notice '  預期的失敗：%', v_err;
end;
$$;
rollback;

\echo '== integrity: 0017 的 drop→backfill→add 順序（review P）=='
begin;
-- 重現「套用 0017 之前」的環境：拿掉新 check、把所有帳本降回 6 碼、裝回舊的 6 碼 check。
alter table public.ledgers drop constraint ledgers_invite_code_check;
update public.ledgers set invite_code = 'A7K3QZ' where id = '10000000-0000-0000-0000-000000000001';
insert into public.ledgers (id, name, invite_code)
values ('bbbb0000-0000-0000-0000-00000000000f', '舊帳本', 'B8L4RY');
alter table public.ledgers add constraint ledgers_invite_code_check check (invite_code ~ '^[A-Z0-9]{6}$');

do $$
declare
  v_blocked boolean := false;
  v_err text;
begin
  -- 錯的順序（先 backfill 再 drop）：舊的 6 碼 check 還在，寫 10 碼一定被擋。
  begin
    update public.ledgers set invite_code = public.gen_invite_code()
     where invite_code !~ '^[A-Z0-9]{10}$';
  exception when check_violation then v_blocked := true; v_err := sqlerrm;
  end;
  assert v_blocked, '舊 check 還在的情況下，backfill 竟然沒被擋（那 P 就不是問題了）';
  raise notice '  這就是 P：先 backfill 再 drop 會炸 → %', v_err;
end;
$$;

do $$
declare
  v_code text;
begin
  -- 正確順序：drop → backfill → add，就是 0017 現在的寫法。
  alter table public.ledgers drop constraint if exists ledgers_invite_code_check;
  update public.ledgers set invite_code = public.gen_invite_code()
   where invite_code !~ '^[A-Z0-9]{10}$';
  alter table public.ledgers add constraint ledgers_invite_code_check
    check (invite_code ~ '^[A-Z0-9]{10}$');

  select invite_code into v_code from public.ledgers where id = 'bbbb0000-0000-0000-0000-00000000000f';
  assert v_code ~ '^[A-Z0-9]{10}$', format('舊帳本的邀請碼應被補成 10 碼，實際 %s', v_code);
  assert v_code <> 'B8L4RY', '舊邀請碼應該被換掉（這也是 O 記在已知風險的那件事）';
  assert (select count(*) from public.ledgers where invite_code !~ '^[A-Z0-9]{10}$') = 0,
    '所有帳本的邀請碼都該補成 10 碼';
end;
$$;
rollback;

\echo '== integrity: 邀請碼 10 碼、CSPRNG、不重複（review 19）=='
begin;
do $$
declare
  v_codes text[];
begin
  select array_agg(public.gen_invite_code()) into v_codes from generate_series(1, 50);
  assert (select bool_and(c ~ '^[A-Z0-9]{10}$') from unnest(v_codes) c),
    '邀請碼格式應為 10 碼大寫英數';
  assert (select count(distinct c) from unnest(v_codes) c) = 50, '50 次抽樣不該出現重複';
  assert (select bool_and(c !~ '[01IO]') from unnest(v_codes) c),
    '邀請碼不該含易混淆字元 0/1/I/O';
  assert (select invite_code from public.ledgers where id = '10000000-0000-0000-0000-000000000001') = 'A7K3QZM4XB',
    '種子邀請碼應為 10 碼';
end;
$$;
rollback;

\echo 'integrity.sql PASS'
