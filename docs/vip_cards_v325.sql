-- v3.20.0-p6：后台免费额度管理（读今日用量 / 给单个用户重置当天额度）幂等
-- 依赖：docs/vip_cards_v324.sql（free_usage / cfg_int / is_admin）

-- 1) 管理员看今日免费额度总览（含每人用量，供后台用户表显示）
create or replace function public.admin_free_stat()
returns jsonb language plpgsql security definer set search_path = public as $$
declare lim int; tot int; usrs int; rowsj jsonb;
begin
  if not public.is_admin() then raise exception '需要管理员权限'; end if;
  lim := greatest(1, least(50, public.cfg_int('free_bk_limit', 5)));
  select coalesce(sum(t.c), 0), count(*) into tot, usrs
    from (select uid, count(*) c from public.free_usage where day = current_date group by uid) t;
  select coalesce(jsonb_agg(jsonb_build_object('uid', uid, 'used', c) order by c desc), '[]'::jsonb)
    into rowsj
    from (select uid, count(*) c from public.free_usage where day = current_date group by uid) t;
  return jsonb_build_object('ok', true, 'day', current_date, 'limit', lim,
                            'total', tot, 'users', usrs, 'rows', rowsj);
end $$;
grant execute on function public.admin_free_stat() to authenticated;

-- 2) 给某个用户重置「今天」的免费额度（不影响历史记录，不影响会员）
create or replace function public.admin_free_reset(p_uid uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_admin() then raise exception '需要管理员权限'; end if;
  if p_uid is null then raise exception '缺少用户 uid'; end if;
  delete from public.free_usage where uid = p_uid and day = current_date;
  get diagnostics n = row_count;
  insert into public.audit_log(actor, action, target, detail)
    values (auth.uid(), 'free_reset', p_uid::text, jsonb_build_object('deleted', n, 'day', current_date));
  return jsonb_build_object('ok', true, 'deleted', n);
end $$;
grant execute on function public.admin_free_reset(uuid) to authenticated;
