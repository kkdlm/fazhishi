-- 临时探针：验证 docs/*.sql push 后是否会自动执行（配了 SUPABASE_DB_URL 才会真正跑）
create table if not exists public.migration_probe (
  id int primary key,
  at timestamptz default now()
);
alter table public.migration_probe enable row level security;
drop policy if exists migration_probe_read on public.migration_probe;
create policy migration_probe_read on public.migration_probe for select using (true);
insert into public.migration_probe(id) values (1) on conflict (id) do nothing;
