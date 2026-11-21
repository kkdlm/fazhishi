-- 4.0.5 补丁 10：把 profiles / progress 加入 Supabase 实时广播，让后台改动秒级推到用户端
-- 幂等：重复执行不会报错

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'profiles'
  ) then
    alter publication supabase_realtime add table public.profiles;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'progress'
  ) then
    alter publication supabase_realtime add table public.progress;
  end if;
end $$;

-- update 事件带上完整行，前端才能拿到最新 pro_until / banned
alter table public.profiles replica identity full;
