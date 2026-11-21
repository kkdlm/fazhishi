-- 法制史一点通 · v3.20.0 数据库增量（第 10 段，幂等可重复执行）
-- 作用：1) 堵住“普通用户改自己 pro_until 白嫖会员”；2) 管理员加/减会员、封禁、备注改为带权限校验的函数并记审计
-- 用法：Supabase SQL Editor 整段粘贴 → Run

create or replace function public.ensure_profile()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then return; end if;
  insert into public.profiles (uid, email, last_seen)
  values (auth.uid(), (select u.email from auth.users u where u.id = auth.uid()), now())
  on conflict (uid) do update set last_seen = now();
end $$;
grant execute on function public.ensure_profile() to authenticated;

revoke insert, update, delete on table public.profiles from authenticated;
revoke insert, update, delete on table public.profiles from anon;
grant update (last_seen, nickname) on table public.profiles to authenticated;

create or replace function public.admin_set_vip(p_uid uuid, p_days int)
returns timestamptz
language plpgsql security definer set search_path = public as $$
declare v timestamptz;
begin
  if not public.is_admin() then raise exception '需要管理员权限'; end if;
  if coalesce(p_days,0) <= 0 then
    update public.profiles set pro_until = null where uid = p_uid returning pro_until into v;
    insert into public.audit_log(actor, action, target, detail)
      values (auth.uid(), 'vip_clear', p_uid::text, jsonb_build_object('at', now()));
    return null;
  end if;
  update public.profiles
     set pro_until = greatest(coalesce(pro_until, now()), now()) + (p_days || ' days')::interval
   where uid = p_uid
   returning pro_until into v;
  insert into public.audit_log(actor, action, target, detail)
    values (auth.uid(), 'vip_add', p_uid::text, jsonb_build_object('days', p_days, 'until', v));
  return v;
end $$;
grant execute on function public.admin_set_vip(uuid, int) to authenticated;

create or replace function public.admin_set_banned(p_uid uuid, p_banned boolean)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理员权限'; end if;
  update public.profiles set banned = coalesce(p_banned,false) where uid = p_uid;
  insert into public.audit_log(actor, action, target, detail)
    values (auth.uid(), case when p_banned then 'ban' else 'unban' end, p_uid::text, '{}'::jsonb);
  return coalesce(p_banned,false);
end $$;
grant execute on function public.admin_set_banned(uuid, boolean) to authenticated;

create or replace function public.admin_set_note(p_uid uuid, p_note text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理员权限'; end if;
  update public.profiles set note = nullif(trim(coalesce(p_note,'')),'') where uid = p_uid;
end $$;
grant execute on function public.admin_set_note(uuid, text) to authenticated;
