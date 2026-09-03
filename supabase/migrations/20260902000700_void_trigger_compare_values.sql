-- Migration 0007 — void trigger 改成「比值」而非「有沒有被寫到」
--
-- 坑：`after update of <欄位>` 的語意是「欄位出現在 SET 清單就觸發」，值有沒有變不管。
-- PostgREST／supabase_flutter 的整列 update 會把所有欄位都放進 SET，
-- 於是「只想改備註」也會把結算打掉。加 when 子句比對新舊值即可，
-- 整列 update 只要金額相關欄位的值沒變就不 void。
--
-- 注意 when 子句不能在 delete 事件裡引用 new，所以 update 與 delete/insert 拆成兩支 trigger。
-- 用 create or replace trigger（PG14+）取代原本的定義，不用 drop。

-- entries：update 比值，delete 照舊一律 void。
create or replace trigger entries_void_pending_settlement_trg
  after update of amount, payer_id, split_method, scope, kind on public.entries
  for each row
  when (
       old.amount       is distinct from new.amount
    or old.payer_id     is distinct from new.payer_id
    or old.split_method is distinct from new.split_method
    or old.scope        is distinct from new.scope
    or old.kind         is distinct from new.kind
  )
  execute function public.entries_void_pending_settlement();

create or replace trigger entries_void_pending_settlement_del_trg
  after delete on public.entries
  for each row execute function public.entries_void_pending_settlement();

-- entry_splits：同理比 share／member_id；insert 與 delete 一律 void（分攤集合本身變了）。
create or replace trigger entry_splits_void_pending_settlement_trg
  after update of share, member_id on public.entry_splits
  for each row
  when (
       old.share     is distinct from new.share
    or old.member_id is distinct from new.member_id
  )
  execute function public.entry_splits_void_pending_settlement();

create or replace trigger entry_splits_void_pending_settlement_ins_del_trg
  after insert or delete on public.entry_splits
  for each row execute function public.entry_splits_void_pending_settlement();
