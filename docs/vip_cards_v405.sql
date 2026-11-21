-- 4.0.5：后台日志页顶部统计（最近 N 天共多少条、多少人）
create or replace function public.admin_log_daily(p_days int default 7)
returns table(days int, total bigint, users bigint)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理员权限'; end if;
  if p_days is null or p_days < 1 or p_days > 90 then p_days := 7; end if;
  return query
    select p_days, count(*)::bigint, count(distinct l.uid)::bigint
      from public.activity_log l
     where l.created_at > now() - make_interval(days => p_days);
end $$;
grant execute on function public.admin_log_daily(int) to authenticated;
insert into public.migration_probe (id, at) values (14, now()) on conflict (id) do update set at = excluded.at;
