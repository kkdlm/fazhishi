-- 4.0.3 日志：写入 + 用户读自己的
create or replace function public.log_activity(
  p_action text, p_target text default null, p_detail jsonb default '{}'::jsonb
) returns void
language plpgsql security definer set search_path = public as $$
declare
  m record; d jsonb := '{}'::jsonb; u uuid := auth.uid(); n int; ks text[];
begin
  if u is null then return; end if;
  select * into m from public.log_meta(p_action);
  if m.label is null then return; end if;
  select count(*) into n from public.activity_log
   where uid = u and action = p_action and created_at > now() - interval '60 seconds';
  if n >= 12 then return; end if;
  ks := coalesce(m.keys, '{}'::text[]);
  if jsonb_typeof(p_detail) = 'object' then
    select coalesce(jsonb_object_agg(e.k, e.v), '{}'::jsonb) into d
      from jsonb_each(p_detail) as e(k, v)
     where e.k = any(ks) and jsonb_typeof(e.v) in ('string','number','boolean');
  end if;
  insert into public.activity_log(uid, action, target, detail, vis)
    values (u, p_action, left(nullif(p_target, ''), 60), coalesce(d, '{}'::jsonb), m.vis);
end $$;
grant execute on function public.log_activity(text, text, jsonb) to authenticated;

create or replace function public.my_logs(
  p_limit int default 30, p_offset int default 0, p_act text default null
) returns table(id bigint, act text, label text, target text, detail jsonb, at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '需要登录';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 120 then p_limit := 30; end if;
  if p_offset is null or p_offset < 0 then p_offset := 0; end if;
  return query
    select l.id, l.action,
           coalesce((select m1.label from public.log_meta(l.action) as m1 limit 1), l.action),
           l.target, l.detail, l.created_at
      from public.activity_log l
     where l.uid = auth.uid() and l.vis = 'self'
       and (p_act is null or l.action = p_act)
     order by l.created_at desc, l.id desc
     limit p_limit offset p_offset;
end $$;
grant execute on function public.my_logs(int, int, text) to authenticated;
insert into public.migration_probe (id, at) values (10, now()) on conflict (id) do update set at = excluded.at;
