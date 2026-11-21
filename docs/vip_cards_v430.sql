-- ============================================================
--  v4.0.3 操作日志：用户能看自己的操作记录，管理员能看全部
--  幂等，可重复跑（push docs/*.sql 后由 .github/workflows/db.yml 自动执行）
-- ============================================================

-- 1) 日志表（不直接开放读写，一律走下面的函数）
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

-- 2) 动作字典：中文名 + 可见性 + 允许保留的 detail 字段
create or replace function public.log_meta(p_act text)
returns table(label text, vis text, keys text[])
language sql immutable as $$
  select v.a, v.l, v.s, v.k
    from (values
      ('login',        '登录',            'self' , array['method','device']),
      ('logout',       '退出登录',        'self' , array['device']),
      ('signup',       '注册账号',        'self' , array['method','invited']),
      ('pwd_change',   '修改密码',        'self' , array[]::text[]),
      ('pwd_reset',    '重置密码',        'self' , array['method']),
      ('card_redeem',  '兑换卡密',        'self' , array['days','prefix','card_type']),
      ('card_fail',    '兑换失败',        'self' , array['reason','prefix']),
      ('vip_on',       '会员开通 / 续期', 'self' , array['days','until','by']),
      ('vip_off',      '会员取消 / 到期', 'self' , array['until']),
      ('device_bind',  '绑定设备',        'self' , array['tail','devices','limit']),
      ('device_unbind','解绑设备',        'self' , array['tail','devices']),
      ('invite_gen',   '生成邀请码',      'self' , array['code']),
      ('invite_claim', '邀请成功',        'self' , array['code','days_inviter','days_invitee','who']),
      ('export',       '导出数据',        'self' , array['what','count']),
      ('delete_request','申请注销',       'self' , array[]::text[]),
      ('free_quota',   '免费额度用完',    'self' , array['limit']),
      ('sync',         '同步进度',        'admin', array['rev','items']),
      ('app_open',     '打开应用',        'admin', array['ver']),
      ('bug_report',   '报错提交',        'admin', array['where','kind'])
    ) v(a,l,s,k)
   where v.a = p_act;
$$;

-- 3) 写日志（App 里调这个；动作必须命中字典，detail 只留白名单字段）
create or replace function public.log_activity(
  p_action text, p_target text default null, p_detail jsonb default '{}'::jsonb
) returns void
language plpgsql security definer set search_path = public as $$
declare
  m record;
  d jsonb := '{}'::jsonb;
  u uuid := auth.uid();
  n int;
begin
  if u is null then return; end if;
  select * into m from public.log_meta(p_action);
  if m.label is null then return; end if;
  select count(*) into n from public.activity_log
   where uid = u and action = p_action and created_at > now() - interval '60 seconds';
  if n >= 12 then return; end if;
  if jsonb_typeof(p_detail) = 'object' then
    select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) into d
      from jsonb_each(p_detail) as e(k, v)
     where k = any(m.keys)
       and jsonb_typeof(v) in ('string','number','boolean');
  end if;
  insert into public.activity_log(uid, action, target, detail, vis)
    values (u, p_action, left(nullif(p_target, ''), 60), coalesce(d, '{}'::jsonb), m.vis);
end $$;
grant execute on function public.log_activity(text, text, jsonb) to authenticated;

-- 4) 用户读自己的：只出 vis=self 的，字段全部服务端过滤
create or replace function public.my_logs(
  p_limit int default 30, p_offset int default 0, p_act text default null
) returns table(id bigint, act text, label text, target text, detail jsonb, at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '需要登录'; end if;
  if p_limit is null or p_limit < 1 or p_limit > 120 then p_limit := 30; end if;
  if p_offset is null or p_offset < 0 then p_offset := 0; end if;
  return query
    select l.id, l.action, coalesce(m.label, l.action), l.target, l.detail, l.created_at
      from public.activity_log l
      left join lateral public.log_meta(l.action) m on true
     where l.uid = auth.uid()
       and l.vis = 'self'
       and (p_act is null or l.action = p_act)
     order by l.created_at desc, l.id desc
     limit p_limit offset p_offset;
end $$;
grant execute on function public.my_logs(int, int, text) to authenticated;

-- 5) 管理员看全部：用户操作（activity_log）+ 后台动作（audit_log）
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
       where (p_uid is null or l.uid = p_uid)
         and (p_act is null or l.action = p_act)
       order by l.created_at desc, l.id desc
       limit p_limit offset p_offset;
  end if;
end $$;
grant execute on function public.admin_logs(int, int, text, uuid, text) to authenticated;

-- 6) 后台统计用：按动作统计最近 N 天
create or replace function public.admin_log_stat(p_days int default 7)
returns table(act text, label text, total bigint)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理员权限'; end if;
  if p_days is null or p_days < 1 or p_days > 90 then p_days := 7; end if;
  return query
    select l.action, coalesce(m.label, l.action), count(*)::bigint
      from public.activity_log l
      left join lateral public.log_meta(l.action) m on true
     where l.created_at > now() - (p_days || ' days')::interval
     group by l.action, m.label
     order by 3 desc;
end $$;
grant execute on function public.admin_log_stat(int) to authenticated;

-- 7) 老日志清理（可选，保留 180 天）
-- delete from public.activity_log where created_at < now() - interval '180 days';

insert into public.migration_probe (id, at) values (7, now())
on conflict (id) do update set at = excluded.at;
