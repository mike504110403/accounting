-- Migration 0026 — Realtime publication 四表 replica identity full
-- Realtime DELETE 事件在預設 replica identity（主鍵）下帶不出 ledger_id，
-- 前端只能掛不帶 filter 的 DELETE 訂閱＋整表重抓（realtime.dart 的繞路，2026-09-03 DATA review）。
-- 四張進 publication 的表改 replica identity full：DELETE payload 帶整列舊值，
-- 前端訂閱得以依 ledger_id 過濾。寫入頻率是夫妻記帳等級，full 的 WAL 額外量可忽略。
alter table public.entries replica identity full;
alter table public.settlements replica identity full;
alter table public.list_items replica identity full;
alter table public.budget_allocation replica identity full;
