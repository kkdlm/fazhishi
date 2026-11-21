-- 4.0.3 日志：第 4 段（后台看全部）
create or replace function public.admin_logs(
  p_limit int default 50, p_offset int default 0,
  p_source text default 'user', p_uid uuid default null, p_act text default null
) returns table(src text, id bigint, uid uuid, email text, act text, label text,
                target text, detail jsonb, at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理员权限'; end if;
  if p_limit is null or p_limit < 1 or p_limit > 300 then p_limit := 50; end if;
  if p_offset is null or p_offset < 0 then p_offset := 0; end if;
  if p_source = 'admin' then
    return query
      select 'admin'::text, a.id, a.actor, p.email, a.action,
             coalesce(m.label, a.action), a.target, a.detail, a.created_at
        from public.audit_log a
        left join public.profiles p on p.uid = a.actor
        left join lateral public.log_meta(a.action) m on true
       where (p_act is null or a.action = p_act)
       order by a.created_at desc, a.id desc
       limit p_limit offset p_offset;
  else
    return query
      select 'user'::text, l.id, l.uid, p.email, l.action,
             coalesce(m.label, l.action), l.target, l.detail, l.created_at
        from public.activity_log l
        left join public.profiles p on p.uid = l.uid
        left join lateral public.log_meta(l.action) m on true
       where (p_uid is null or l.uid = p_uid) and (p_act is null or l.action = p_act)
       order by l.created_at desc, l.id desc
       limit p_limit offset p_offset;
  end if;
end $$;
grant execute on function public.admin_logs(int, int, text, uuid, text) to authenticated;
insert into public.migration_probe (id, at) values (11, now()) on conflict (id) do update set at = excluded.at;
