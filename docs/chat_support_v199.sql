-- ============================================================
-- 法制史一点通 · 客服 + 地区统计 一次性初始化（v1.1.9.9）
-- 可重复执行 / 幂等；GitHub Actions db.yml 会自动执行本文件
-- ============================================================

-- 1) 用户地区字段
alter table profiles add column if not exists ip         text;
alter table profiles add column if not exists ip_prov    text;   -- 省/直辖市
alter table profiles add column if not exists ip_city    text;   -- 城市
alter table profiles add column if not exists ip_isp     text;   -- 运营商/网络
alter table profiles add column if not exists geo_at     timestamptz;

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
  kind        text not null default 'text',      -- text | order | card | pay | paid | system
  body        text,
  meta        jsonb,
  created_at  timestamptz not null default now(),
  seen_admin  boolean not null default false,
  seen_user   boolean not null default false
);
create index if not exists support_msgs_uid_id_idx on support_msgs (uid, id desc);

grant usage on sequence support_msgs_id_seq to authenticated;
grant select, insert on support_msgs to authenticated;

alter table support_msgs enable row level security;
drop policy if exists support_msgs_self_read on support_msgs;
create policy support_msgs_self_read on support_msgs
  for select to authenticated using (uid = auth.uid());

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

create or replace function chat_is_admin()
returns boolean
language sql
stable
as $$
  select coalesce((auth.jwt() ->> 'email') = '2116829553@qq.com', false);
$$;

-- 会话列表：以「全部注册用户」为骨架，未聊过也算一条线程，便于管理员主动发起
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
    select p.uid,
           p.email,
           p.nickname as nick,
           p.ip_prov,
           p.ip_city,
           p.last_seen,
           coalesce(max(m.id), 0)                                    as last_id,
           (array_agg(m.body order by m.id desc) filter (where m.id is not null))[1] as last_body,
           (array_agg(m.role order by m.id desc) filter (where m.id is not null))[1] as last_role,
           max(m.created_at)                                          as last_at,
           coalesce(sum(case when m.role = 'user' and m.seen_admin = false then 1 else 0 end), 0)::int as unread,
           (max(m.id) is not null)                                    as has_msg
      from profiles p
      left join support_msgs m on m.uid = p.uid
     group by p.uid, p.email, p.nickname, p.ip_prov, p.ip_city, p.last_seen
     order by coalesce(sum(case when m.role = 'user' and m.seen_admin = false then 1 else 0 end), 0) desc,
              coalesce(max(m.id), 0) desc,
              p.last_seen desc nulls last
     limit 500
  ) t;
  return coalesce(arr, '[]'::json);
end $$;

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

-- 管理员回复 / 发卡密 / 发收款码 / 发系统消息
create or replace function admin_chat_reply(p_uid uuid, p_body text, p_kind text default 'text', p_meta jsonb default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare new_id bigint;
begin
  if not chat_is_admin() then raise exception 'not admin'; end if;
  if coalesce(trim(p_body), '') = '' and coalesce(nullif(p_kind, ''), 'text') not in ('pay') then
    raise exception '内容不能为空';
  end if;
  insert into support_msgs (uid, role, kind, body, meta)
  values (p_uid, 'admin', coalesce(nullif(p_kind, ''), 'text'), p_body, p_meta)
  returning id into new_id;
  update support_msgs set seen_admin = true where uid = p_uid and role = 'user' and seen_admin = false;
  return json_build_object('ok', true, 'id', new_id);
end $$;

select 'support ready v199'::text as result;
