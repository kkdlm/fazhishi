-- v4.0.3 操作日志：表 + 字典 + 写入 + 用户读自己 + 管理员读全部 + 按动作统计（幂等，整段可重跑）

create table if not exists public.activity_log (
  id         bigserial primary key,
  uid        uuid,
  action     text not null,
  target     text,
  detail     jsonb not null default '{}'::jsonb,
  vis        text not null default 'self',
  created_at timestamptz not null default now()
);
create index if not exists act_uid_idx  on public.activity_log(uid, created_at desc);
create index if not exists act_time_idx on public.activity_log(created_at desc);
alter table public.activity_log enable row level security;

create or replace function public.log_meta(p_act text)
returns table(label text, vis text, keys text[])
language sql immutable as $$
  select
    case p_act
      when 'login'          then '登录'
      when 'logout'         then '退出登录'
      when 'signup'         then '注册账号'
      when 'pwd_change'     then '修改密码'
      when 'pwd_reset'      then '重置密码'
      when 'card_redeem'    then '兑换卡密'
      when 'card_fail'      then '兑换失败'
      when 'vip_on'         then '会员开通或续期'
      when 'vip_off'        then '会员取消或到期'
      when 'device_bind'    then '绑定设备'
      when 'device_unbind'  then '解绑设备'
      when 'invite_gen'     then '生成邀请码'
      when 'invite_claim'   then '邀请成功'
      when 'export'         then '导出数据'
      when 'delete_request' then '申请注销'
      when 'free_quota'     then '免费额度用完'
      when 'sync'           then '同步进度'
      when 'app_open'       then '打开应用'
      when 'bug_report'     then '提交问题反馈'
      else null
    end,
    case p_act
      when 'sync' then 'admin'
      when 'app_open' then 'admin'
      when 'bug_report' then 'admin'
      else 'self'
    end,
    case p_act
      when 'login'          then '{method,device}'::text[]
      when 'logout'         then '{device}'::text[]
      when 'signup'         then '{method,invited}'::text[]
      when 'pwd_reset'      then '{method}'::text[]
      when 'card_redeem'    then '{days,prefix,card_type}'::text[]
      when 'card_fail'      then '{reason,prefix}'::text[]
      when 'vip_on'         then '{days,until,by}'::text[]
      when 'vip_off'        then '{until}'::text[]
      when 'device_bind'    then '{tail,devices,limit}'::text[]
      when 'device_unbind'  then '{tail,devices}'::text[]
      when 'invite_gen'     then '{code}'::text[]
      when 'invite_claim'   then '{code,days_inviter,days_invitee,who}'::text[]
      when 'export'         then '{what,count}'::text[]
      when 'free_quota'     then '{limit}'::text[]
      when 'sync'           then '{rev,items}'::text[]
      when 'app_open'       then '{ver}'::text[]
      when 'bug_report'     then '{where,kind}'::text[]
      else '{}'::text[]
    end
$$;

create or replace function public.log_activity(
  p_action text, p_target text default null, p_detail jsonb default '{}'::jsonb
) returns void
language plpgsql security definer set search_path = public as $$
declare
  m record;
  d jsonb := '{}'::jsonb;
  u uuid := auth.uid();
  n int;
  ks text[];
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
     where e.k = any(ks)
       and jsonb_typeof(e.v) in ('string','number','boolean');
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
  if auth.uid() is null then raise exception '需要登录'; end if;
  if p_limit is null or p_limit < 1 or p_limit > 120 then p_limit := 30; end if;
  if p_offset is null or p_offset < 0 then p_offset := 0; end if;
  return query
    select l.id, l.action,
           coalesce((select m1.label from public.log_meta(l.action) as m1 limit 1), l.action),
           l.target, l.detail, l.created_at
      from public.activity_log l
     where l.uid = auth.uid()
       and l.vis = 'self'
       and (p_act is null or l.action = p_act)
     order by l.created_at desc, l.id desc
     limit p_limit offset p_offset;
end $$;
grant execute on function public.my_logs(int, int, text) to authenticated;

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
             coalesce((select m1.label from public.log_meta(a.action) as m1 limit 1), a.action),
             a.target, a.detail, a.created_at
        from public.audit_log a
        left join public.profiles p on p.uid = a.actor
       where (p_act is null or a.action = p_act)
       order by a.created_at desc, a.id desc
       limit p_limit offset p_offset;
  else
    return query
      select 'user'::text, l.id, l.uid, p.email, l.action,
             coalesce((select m1.label from public.log_meta(l.action) as m1 limit 1), l.action),
             l.target, l.detail, l.created_at
        from public.activity_log l
        left join public.profiles p on p.uid = l.uid
       where (p_uid is null or l.uid = p_uid)
         and (p_act is null or l.action = p_act)
       order by l.created_at desc, l.id desc
       limit p_limit offset p_offset;
  end if;
end $$;
grant execute on function public.admin_logs(int, int, text, uuid, text) to authenticated;

create or replace function public.admin_log_stat(p_days int default 7)
returns table(act text, label text, total bigint)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理员权限'; end if;
  if p_days is null or p_days < 1 or p_days > 90 then p_days := 7; end if;
  return query
    select l.action,
           coalesce((select m1.label from public.log_meta(l.action) as m1 limit 1), l.action),
           count(*)::bigint
      from public.activity_log l
     where l.created_at > now() - make_interval(days => p_days)
     group by l.action
     order by 3 desc;
end $$;
grant execute on function public.admin_log_stat(int) to authenticated;

insert into public.migration_probe (id, at) values (7, now())
on conflict (id) do update set at = excluded.at;
