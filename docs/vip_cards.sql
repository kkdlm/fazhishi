-- 法制史一点通 · 会员／卡密／邀请／设备 服务端结构（v3.19.0 版，幂等可重复执行）
-- 用法：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run（只需一次）
-- 自动：push 本文件后 .github/workflows/db.yml 会尝试执行（需 secret SUPABASE_DB_URL）
-- 说明：profiles 表里 pro_until（会员到期）、banned（封禁）、role（权限）都是已有字段，
--      本文件不新建重复列，只补备注列 + 卡密/邀请/设备/审计/配置表 + 相关函数。

-- 1) 后台「备注」用的一列（其余会员字段沿用库内已有 pro_until / banned / role）
alter table public.profiles add column if not exists note text;

-- 2) 行级权限：本人可读写自己；管理员可读写所有人
drop policy if exists profiles_self_select on public.profiles;
create policy profiles_self_select on public.profiles
  for select using (
    auth.uid() = uid
    or exists (select 1 from public.profiles p where p.uid = auth.uid() and p.role = 'admin'));

drop policy if exists profiles_self_update on public.profiles;
create policy profiles_self_update on public.profiles
  for update using (
    auth.uid() = uid
    or exists (select 1 from public.profiles p where p.uid = auth.uid() and p.role = 'admin'))
  with check (true);

-- 3) 卡密台账（服务端唯一真源）
create table if not exists public.cards (
  code       text primary key,
  days       int  not null check (days between 1 and 3650),
  status     text not null default 'unused',
  used_by    uuid references auth.users(id),
  used_at    timestamptz,
  created_at timestamptz default now()
);
alter table public.cards enable row level security;

drop policy if exists cards_admin_all on public.cards;
create policy cards_admin_all on public.cards
  for all using (
    exists (select 1 from public.profiles p where p.uid = auth.uid() and p.role = 'admin'))
  with check (
    exists (select 1 from public.profiles p where p.uid = auth.uid() and p.role = 'admin'));

-- 4) 兑换：登录用户调用，原子核销，叠加到 pro_until
create or replace function public.redeem_card(p_code text)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_days  int;
  v_until timestamptz;
begin
  if auth.uid() is null then raise exception '请先登录'; end if;

  insert into public.profiles (uid) values (auth.uid())
  on conflict (uid) do nothing;

  update public.cards
     set status = 'used', used_by = auth.uid(), used_at = now()
   where code = trim(p_code) and status = 'unused'
   returning days into v_days;

  if v_days is null then raise exception '卡密无效或已被使用'; end if;

  update public.profiles
     set pro_until = greatest(coalesce(pro_until, now()), now()) + (v_days || ' days')::interval
   where uid = auth.uid()
   returning pro_until into v_until;

  return v_until;
end $$;

revoke all on function public.redeem_card(text) from public;
grant execute on function public.redeem_card(text) to authenticated;

-- ============ 5) 邀请码（幂等） ============
alter table public.profiles add column if not exists invite_code text;
create unique index if not exists profiles_invite_code_uidx
  on public.profiles (upper(invite_code)) where invite_code is not null;

create table if not exists public.referrals (
  id             bigserial primary key,
  code           text not null,
  inviter        uuid not null references auth.users(id) on delete cascade,
  invitee        uuid not null unique references auth.users(id) on delete cascade,
  reward_inviter int not null default 3,
  reward_invitee int not null default 3,
  created_at     timestamptz default now()
);
alter table public.referrals enable row level security;

drop policy if exists referrals_self_select on public.referrals;
create policy referrals_self_select on public.referrals
  for select using (
    auth.uid() in (inviter, invitee)
    or exists (select 1 from public.profiles p where p.uid = auth.uid() and p.role = 'admin'));

-- 生成/取回自己的邀请码（首次调用自动生成）
create or replace function public.ensure_invite_code()
returns text language plpgsql security definer set search_path = public as $$
declare v text; i int;
begin
  if auth.uid() is null then raise exception '请先登录'; end if;
  select invite_code into v from public.profiles where uid = auth.uid();
  if v is not null and v <> '' then return v; end if;
  for i in 1..8 loop
    v := 'FZ' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
    begin
      update public.profiles set invite_code = v where uid = auth.uid() and coalesce(invite_code,'') = '';
      if found then return v; end if;
      select invite_code into v from public.profiles where uid = auth.uid();
      if v is not null and v <> '' then return v; end if;
      v := null;
    exception when unique_violation then
      v := null;
    end;
  end loop;
  raise exception '邀请码生成失败，稍后再试';
end $$;
grant execute on function public.ensure_invite_code() to authenticated;

-- 填邀请码：一次性，双方各加 3 天（天数从 app_config 读，可后台改）
create or replace function public.claim_invite(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_inviter uuid; v_me uuid := auth.uid(); v_until timestamptz;
        v_ri int; v_re int;
begin
  if v_me is null then raise exception '请先登录'; end if;
  if not public.cfg_bool('invite_enabled', true) then
    return jsonb_build_object('ok', false, 'msg', '邀请活动暂时关闭');
  end if;
  v_ri := public.cfg_int('invite_reward_inviter', 3);
  v_re := public.cfg_int('invite_reward_invitee', 3);
  if exists (select 1 from public.referrals where invitee = v_me) then
    return jsonb_build_object('ok', false, 'msg', '这个账号已经用过邀请码了');
  end if;
  select uid into v_inviter from public.profiles
   where upper(coalesce(invite_code,'')) = upper(trim(p_code)) limit 1;
  if v_inviter is null then return jsonb_build_object('ok', false, 'msg', '邀请码不存在'); end if;
  if v_inviter = v_me then return jsonb_build_object('ok', false, 'msg', '不能填自己的邀请码'); end if;

  insert into public.referrals(code, inviter, invitee, reward_inviter, reward_invitee)
  values (upper(trim(p_code)), v_inviter, v_me, v_ri, v_re);

  insert into public.profiles (uid) values (v_inviter) on conflict (uid) do nothing;
  update public.profiles
     set pro_until = greatest(coalesce(pro_until, now()), now()) + (v_ri || ' days')::interval
   where uid = v_inviter;
  update public.profiles
     set pro_until = greatest(coalesce(pro_until, now()), now()) + (v_re || ' days')::interval
   where uid = v_me
   returning pro_until into v_until;

  return jsonb_build_object('ok', true, 'msg', '邀请成功：你 +' || v_re || ' 天，邀请人 +' || v_ri || ' 天',
                            'until', v_until, 'inviter_days', v_ri, 'invitee_days', v_re);
end $$;
grant execute on function public.claim_invite(text) to authenticated;

-- ============ 6) 设备绑定（幂等） ============
create table if not exists public.devices (
  uid        uuid not null references auth.users(id) on delete cascade,
  device_id  text not null,
  ua         text,
  first_seen timestamptz default now(),
  last_seen  timestamptz default now(),
  revoked    boolean default false,
  primary key (uid, device_id)
);
alter table public.devices enable row level security;

drop policy if exists devices_self on public.devices;
create policy devices_self on public.devices
  for all using (
    auth.uid() = uid
    or exists (select 1 from public.profiles p where p.uid = auth.uid() and p.role = 'admin'))
  with check (
    auth.uid() = uid
    or exists (select 1 from public.profiles p where p.uid = auth.uid() and p.role = 'admin'));

-- 登录后登记设备；上限与活跃窗口从 app_config 读
create or replace function public.register_device(p_device text, p_ua text default null, p_limit int default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_known boolean; v_n int; v_list jsonb;
        v_limit int; v_win int;
begin
  if v_me is null then raise exception '请先登录'; end if;
  if coalesce(trim(p_device),'') = '' then raise exception '设备标识为空'; end if;
  v_limit := case when coalesce(p_limit,0) > 0 then p_limit else public.cfg_int('device_limit', 3) end;
  v_win   := public.cfg_int('device_window_days', 45);

  select exists(select 1 from public.devices where uid = v_me and device_id = p_device) into v_known;

  select count(*) into v_n from public.devices
   where uid = v_me and not coalesce(revoked,false) and device_id <> p_device
     and last_seen > now() - (v_win || ' days')::interval;

  if not v_known and v_n >= v_limit then
    select coalesce(jsonb_agg(jsonb_build_object('device_id', device_id, 'ua', ua, 'last_seen', last_seen)
             order by last_seen), '[]'::jsonb) into v_list
      from public.devices
     where uid = v_me and not coalesce(revoked,false) and last_seen > now() - (v_win || ' days')::interval;
    return jsonb_build_object('ok', false, 'msg', '登录设备已达上限（' || v_limit || ' 台）', 'devices', v_list);
  end if;

  insert into public.devices (uid, device_id, ua, last_seen, revoked)
  values (v_me, p_device, p_ua, now(), false)
  on conflict (uid, device_id) do update set last_seen = now(), ua = excluded.ua, revoked = false;

  return jsonb_build_object('ok', true, 'count', v_n + 1);
end $$;
grant execute on function public.register_device(text, text, int) to authenticated;

-- 解绑：只能解自己名下的设备
create or replace function public.unbind_device(p_device text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid();
begin
  if v_me is null then raise exception '请先登录'; end if;
  update public.devices set revoked = true, last_seen = now()
   where uid = v_me and device_id = p_device;
  return jsonb_build_object('ok', found);
end $$;
grant execute on function public.unbind_device(text) to authenticated;

-- ============ 7) 后台操作审计（幂等） ============
create table if not exists public.audit_log (
  id         bigserial primary key,
  actor      uuid,
  action     text not null,
  target     text,
  detail     jsonb,
  created_at timestamptz default now()
);
alter table public.audit_log enable row level security;

drop policy if exists audit_admin_only on public.audit_log;
create policy audit_admin_only on public.audit_log
  for all using (
    exists (select 1 from public.profiles p where p.uid = auth.uid() and p.role = 'admin'));

-- ============ 8) 玩法参数配置（奖励天数只改这里 / 后台「配置」页也可改） ============
create table if not exists public.app_config (
  key        text primary key,
  val        jsonb not null,
  note       text,
  updated_at timestamptz default now()
);
alter table public.app_config enable row level security;
drop policy if exists app_config_read on public.app_config;
create policy app_config_read on public.app_config for select using (true);
drop policy if exists app_config_admin on public.app_config;
create policy app_config_admin on public.app_config
  for all using (
    exists (select 1 from public.profiles p where p.uid = auth.uid() and p.role = 'admin'))
  with check (
    exists (select 1 from public.profiles p where p.uid = auth.uid() and p.role = 'admin'));

insert into public.app_config(key, val, note) values
  ('invite_enabled',        'true'::jsonb, '邀请活动总开关（false=停止发放，已发放不受影响）'),
  ('invite_reward_inviter', '3'::jsonb,    '邀请人加会员天数'),
  ('invite_reward_invitee', '3'::jsonb,    '被邀请人加会员天数'),
  ('device_limit',          '3'::jsonb,    '同一账号同时活跃设备上限'),
  ('device_window_days',    '45'::jsonb,   '设备活跃统计窗口（天）')
on conflict (key) do nothing;

-- 取整数配置，缺失/非法时回落到默认值
create or replace function public.cfg_int(p_key text, p_def int)
returns int language sql stable security definer set search_path = public as $$
  select coalesce(
    (select nullif(regexp_replace(val #>> '{}', '[^0-9]', '', 'g'), '')::int
       from public.app_config where key = p_key),
    p_def);
$$;
grant execute on function public.cfg_int(text, int) to anon, authenticated;

-- 开关配置，允许 true/false
create or replace function public.cfg_bool(p_key text, p_def boolean)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select (val #>> '{}')::boolean from public.app_config where key = p_key),
    p_def);
$$;
grant execute on function public.cfg_bool(text, boolean) to anon, authenticated;
