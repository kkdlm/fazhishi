-- 法制史一点通 · 会员／卡密服务端结构（v3.17.0 补丁 2 版，幂等可重复执行）
-- 自动执行：push 本文件后 .github/workflows/db.yml 会跑（需仓库 secret SUPABASE_DB_URL）
-- 手动执行：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run
-- 说明：profiles 表里 pro_until（会员到期）、banned（封禁）、role（权限）都是已有字段，
--      本文件不新建重复列，只补一个备注列 + 卡密表 + 兑换函数 + 管理员更新放行。

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
