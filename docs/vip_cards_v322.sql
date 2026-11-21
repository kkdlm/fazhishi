-- v3.21.0 数据库增量（第 12 段，幂等）
-- 会员天数改为「可正可负」：p_days>0 加天，p_days<0 减天，p_days=0 取消会员；后台可自定义任意天数。

create or replace function public.admin_set_vip(p_uid uuid, p_days int)
returns timestamptz
language plpgsql security definer set search_path = public as $$
declare v timestamptz; v_new timestamptz;
begin
  if not public.is_admin() then raise exception '需要管理员权限'; end if;

  if coalesce(p_days,0) = 0 then
    update public.profiles set pro_until = null where uid = p_uid returning pro_until into v;
    insert into public.audit_log(actor, action, target, detail)
      values (auth.uid(), 'vip_clear', p_uid::text, jsonb_build_object('at', now()));
    return null;
  end if;

  if p_days > 0 then
    update public.profiles
       set pro_until = greatest(coalesce(pro_until, now()), now()) + (p_days || ' days')::interval
     where uid = p_uid returning pro_until into v;
  else
    v_new := greatest(coalesce((select pro_until from public.profiles where uid = p_uid), now()), now())
             + (p_days || ' days')::interval;
    if v_new <= now() then
      update public.profiles set pro_until = null where uid = p_uid returning pro_until into v;
    else
      update public.profiles set pro_until = v_new where uid = p_uid returning pro_until into v;
    end if;
  end if;

  insert into public.audit_log(actor, action, target, detail)
    values (auth.uid(), case when p_days>0 then 'vip_add' else 'vip_sub' end, p_uid::text,
            jsonb_build_object('days', p_days, 'until', v));
  return v;
end $$;
grant execute on function public.admin_set_vip(uuid, int) to authenticated;
