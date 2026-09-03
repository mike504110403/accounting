-- Migration 0019 — 補齊 FK 欄位索引（複審輪二 H）
-- 沒有索引的 FK 子欄位會讓父表的 delete／update 走全表掃描，
-- 而本 schema 有一票 on delete restrict／cascade，刪分類、刪成員都會踩到。
create index if not exists entries_created_by_idx            on public.entries (created_by);
create index if not exists entries_payer_idx                 on public.entries (payer_id);
create index if not exists settlements_initiated_by_idx      on public.settlements (initiated_by);
create index if not exists settlement_approvals_member_idx   on public.settlement_approvals (member_id);
create index if not exists settlement_signers_member_idx     on public.settlement_signers (member_id);
create index if not exists budgets_category_idx              on public.budgets (category_id);
create index if not exists list_items_category_idx           on public.list_items (category_id);
create index if not exists list_items_assignee_idx           on public.list_items (assignee_id);
create index if not exists list_items_entry_idx              on public.list_items (entry_id);
-- 以下在先前的 migration 已建，用 if not exists 保持這支收齊、可獨立閱讀：
create index if not exists entry_splits_member_idx           on public.entry_splits (member_id);
create index if not exists settlement_entries_entry_idx      on public.settlement_entries (entry_id);
create index if not exists entries_category_idx              on public.entries (category_id);
create index if not exists members_user_id_idx               on public.members (user_id);
