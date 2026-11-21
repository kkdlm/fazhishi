-- 4.2.0：把"实时"做到底
-- 1) sync_ping：60 字节的信号表，progress 一写就自动落一条；后台/多设备只看它，不再搬 32 KB 整行
-- 2) 需要实时的表全部加入 realtime 广播（逐表幂等）
-- 3) free_usage 允许本人读取，今日额度变化才能推到用户端

-- ---------- 信号表 ----------
create table if not exists public.sync_ping (
  uid        uuid primary key references auth.users(id) on delete cascade,
  rev        int4 default 0,
  subject    text,
  updated_at timestamptz default now()
);
alter table public.sync_ping enable row level security;

drop policy if exists sync_ping_self on public.sync_ping;
create policy sync_ping_self on public.sync_ping
  for select using (auth.uid() = uid or public.is_admin());

grant select on public.sync_ping to anon, authenticated;

-- progress 写入 → 自动写 ping（只有更新的 rev 才覆盖，防旧值盖新值）
create or replace function public.ping_progress() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.sync_ping(uid, rev, subject, updated_at)
  values (new.uid, coalesce(new.rev, 0), new.subject, coalesce(new.updated_at, now()))
  on conflict (uid) do update
    set rev = excluded.rev,
        subject = excluded.subject,
        updated_at = excluded.updated_at
    where excluded.rev >= coalesce(sync_ping.rev, 0);
  return null;
end $$;

drop trigger if exists trg_progress_ping on public.progress;
create trigger trg_progress_ping
  after insert or update on public.progress
  for each row execute function public.ping_progress();

-- 回填已有进度，避免新装用户看不到老数据的信号
insert into public.sync_ping(uid, rev, subject, updated_at)
select uid, coalesce(max(rev), 0), null, max(updated_at)
from public.progress
group by uid
on conflict (uid) do update
  set rev = greatest(coalesce(public.sync_ping.rev, 0), coalesce(excluded.rev, 0)),
      updated_at = greatest(coalesce(public.sync_ping.updated_at, now()), coalesce(excluded.updated_at, now()));

-- ---------- 今日额度：允许本人读（原来只撤给了 anon/authenticated，前端读不到就没法实时） ----------
grant select on public.free_usage to authenticated;
drop policy if exists free_usage_self on public.free_usage;
create policy free_usage_self on public.free_usage
  for select using (auth.uid() = uid or public.is_admin());

-- ---------- 广播名单 ----------
do $$
declare t text;
begin
  foreach t in array array['profiles','progress','sync_ping','free_usage','devices','app_config','activity_log','bug_reports','cards']
  loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

alter table public.progress replica identity full;
alter table public.profiles replica identity full;
