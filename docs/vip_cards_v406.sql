-- 4.0.6：后台清理旧日志（只删 activity_log，不动其他表）
create or replace function public.admin_log_purge(p_days int default 180)
returns bigint
language plpgsql security definer set search_path = public as $$
declare n bigint;
begin
  if not public.is_admin() then raise exception '需要管理员权限'; end if;
  if p_days is null or p_days < 7 or p_days > 3650 then p_days := 180; end if;
  delete from public.activity_log l
   where l.created_at < now() - make_interval(days => p_days);
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.admin_log_purge(int) to authenticated;
insert into public.migration_probe (id, at) values (15, now()) on conflict (id) do update set at = excluded.at;
