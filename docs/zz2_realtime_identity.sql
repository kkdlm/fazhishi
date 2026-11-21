-- 4.2.0 收尾：让「今日额度 / 设备 / 站点配置」这几张小表真正具备实时广播能力
--
-- 现象：App 调 free_bk_take 之后，free_usage 的变更通过 WebSocket 一帧都没到，
--       界面要等 3 秒多才自己更新（靠本地定时兜底），等于实时没生效。
-- 根因：postgres_changes 广播 UPDATE/INSERT 时要用 REPLICA IDENTITY 定位行；
--       表没有主键、又没设 full 时，逻辑复制读不到「哪一行变了」，变更就被丢掉。
--       progress / profiles 之前已经处理过（一个自带 (uid,subject) 主键，一个在 405 里设了 full），
--       剩下这几张小表漏了。这里统一补齐，并把它们确保加进 publication。
--
-- 幂等：全部用 if exists / pg_publication_tables 判断，跑几次都一样。
-- 体积：这几张表每行都小（free_usage 一行十几字节），设 full 不会带来可感知的 WAL 增长；
--       progress 那种 32KB 的整行故意不设 full（它有主键，默认 identity 就够）。

alter table if exists public.free_usage  replica identity full;
alter table if exists public.devices     replica identity full;
alter table if exists public.app_config  replica identity full;
alter table if exists public.sync_ping   replica identity full;
alter table if exists public.cards       replica identity full;
alter table if exists public.activity_log replica identity full;
alter table if exists public.bug_reports replica identity full;

grant select on public.free_usage to authenticated;
grant select on public.app_config to authenticated;

do $$
declare
  t text;
  tabs text[] := array['free_usage','devices','app_config','sync_ping','cards','activity_log','bug_reports','profiles','progress'];
begin
  foreach t in array tabs loop
    if to_regclass('public.'||t) is not null
       and not exists (
         select 1 from pg_publication_tables
         where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
       )
    then
      execute format('alter publication supabase_realtime add table public.%I', t);
      raise notice 'added to publication: %', t;
    end if;
  end loop;
end $$;
