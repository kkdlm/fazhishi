-- ============================================================
-- 法制史一点通 · 客服 + 地区统计 一次性初始化
-- push 到 docs/*.sql 后由 db-migrate 自动执行（幂等，可重复跑）
-- ============================================================

-- 1) 用户地区字段
alter table profiles add column if not exists ip         text;
alter table profiles add column if not exists ip_prov    text;   -- 省/直辖市
alter table profiles add column if not exists ip_city    text;   -- 城市
alter table profiles add column if not exists ip_isp     text;   -- 运营商/网络
alter table profiles add column if not exists geo_at     timestamptz;

-- 客户端上报自己的出口 IP 与归属地
create or replace function save_geo(p_ip text, p_prov text, p_city text, p_isp text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare u uuid := auth.uid();
begin
  if u is null then return json_build_object('ok', false, 'msg', 'login first'); end if;
  update profiles
     set ip = left(coalesce(p_ip, ''), 64),
         ip_prov = left(coalesce(p_prov, ''), 32),
         ip_city = left(coalesce(p_city, ''), 32),
         ip_isp  = left(coalesce(p_isp, ''), 48),
         geo_at  = now()
   where uid = u;
  return json_build_object('ok', true);
end $$;

-- 2) 客服消息表
create table if not exists support_msgs (
  id          bigserial primary key,
  uid         uuid not null,
  role        text not null default 'user',      -- user | admin
  kind        text not null default 'text',      -- text | order | card | system
  body        text,
  meta        jsonb,
  created_at  timestamptz not null default now(),
  seen_admin  boolean not null default false,
  seen_user   boolean not null default false
);
create index if not exists support_msgs_uid_id_idx on support_msgs (uid, id desc);

grant usage on sequence support_msgs_id_seq to authenticated;
grant select, insert on support_msgs to authenticated;

-- 表级权限只给自己看自己的；写入统一走下面的函数
alter table support_msgs enable row level security;
drop policy if exists support_msgs_self_read on support_msgs;
create policy support_msgs_self_read on support_msgs
  for select to authenticated using (uid = auth.uid());

-- 用户发消息（限速 2 秒一条）
create or replace function chat_send(p_body text, p_kind text default 'text', p_meta jsonb default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare u uuid := auth.uid(); last_at timestamptz; new_id bigint;
begin
  if u is null then raise exception '先登录'; end if;
  if coalesce(trim(p_body), '') = '' then raise exception '内容不能为空'; end if;
  if length(p_body) > 800 then raise exception '太长了'; end if;
  select max(created_at) into last_at from support_msgs where uid = u and role = 'user';
  if last_at is not null and now() - last_at < interval '2 seconds' then
    raise exception '发得太快，等几秒';
  end if;
  insert into support_msgs (uid, role, kind, body, meta)
  values (u, 'user', coalesce(nullif(p_kind, ''), 'text'), p_body, p_meta)
  returning id into new_id;
  return json_build_object('ok', true, 'id', new_id);
end $$;

-- 用户拉自己的会话（并把管理员消息标记为已读）
create or replace function chat_pull(p_since bigint default 0)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare u uuid := auth.uid(); arr json;
begin
  if u is null then return json_build_object('ok', false, 'msgs', json_build_array()); end if;
  select json_agg(t) into arr from (
    select id, role, kind, body, meta, created_at
      from support_msgs
     where uid = u and id > coalesce(p_since, 0)
     order by id
     limit 200
  ) t;
  update support_msgs set seen_user = true
    where uid = u and role = 'admin' and seen_user = false;
  return json_build_object('ok', true, 'msgs', coalesce(arr, '[]'::json));
end $$;

-- 用户未读数（进「我的」页时拉一次，用来显示红点）
create or replace function chat_unread()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare u uuid := auth.uid(); n int;
begin
  if u is null then return json_build_object('ok', false, 'n', 0); end if;
  select count(*) into n from support_msgs where uid = u and role = 'admin' and seen_user = false;
  return json_build_object('ok', true, 'n', n);
end $$;

-- ============ 管理员侧（只有白名单邮箱能调） ============
-- 管理员邮箱写在下面两处，换人时改这里即可
create or replace function chat_is_admin()
returns boolean
language sql
stable
as $$
  select coalesce((auth.jwt() ->> 'email') = '2116829553@qq.com', false);
$$;

-- 会话列表：每个用户最后一条 + 未读数
create or replace function admin_chat_threads()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare arr json;
begin
  if not chat_is_admin() then raise exception 'not admin'; end if;
  select json_agg(t) into arr from (
    select m.uid,
           p.email,
           p.nick,
           p.ip_prov,
           p.ip_city,
           max(m.id)                                  as last_id,
           (array_agg(m.body order by m.id desc))[1]  as last_body,
           (array_agg(m.role order by m.id desc))[1]  as last_role,
           max(m.created_at)                          as last_at,
           sum(case when m.role = 'user' and m.seen_admin = false then 1 else 0 end)::int as unread
      from support_msgs m
      left join profiles p on p.uid = m.uid
     group by m.uid, p.email, p.nick, p.ip_prov, p.ip_city
     order by max(m.id) desc
     limit 200
  ) t;
  return coalesce(arr, '[]'::json);
end $$;

-- 某个用户的全部消息（管理员看，并把用户消息标记为已读）
create or replace function admin_chat_msgs(p_uid uuid, p_since bigint default 0)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare arr json;
begin
  if not chat_is_admin() then raise exception 'not admin'; end if;
  select json_agg(t) into arr from (
    select id, role, kind, body, meta, created_at, seen_admin, seen_user
      from support_msgs
     where uid = p_uid and id > coalesce(p_since, 0)
     order by id
     limit 300
  ) t;
  update support_msgs set seen_admin = true
    where uid = p_uid and role = 'user' and seen_admin = false;
  return json_build_object('ok', true, 'msgs', coalesce(arr, '[]'::json));
end $$;

-- 管理员回复 / 发卡密 / 发系统消息
create or replace function admin_chat_reply(p_uid uuid, p_body text, p_kind text default 'text', p_meta jsonb default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare new_id bigint;
begin
  if not chat_is_admin() then raise exception 'not admin'; end if;
  if coalesce(trim(p_body), '') = '' then raise exception '内容不能为空'; end if;
  insert into support_msgs (uid, role, kind, body, meta)
  values (p_uid, 'admin', coalesce(nullif(p_kind, ''), 'text'), p_body, p_meta)
  returning id into new_id;
  update support_msgs set seen_admin = true where uid = p_uid and role = 'user' and seen_admin = false;
  return json_build_object('ok', true, 'id', new_id);
end $$;

select 'support ready'::text as result;
