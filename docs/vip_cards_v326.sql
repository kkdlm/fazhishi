-- v3.21.0 用户系统完善：App 内自助查看/解绑登录设备
-- 幂等：可重复执行

-- 1) 本人设备清单（含上限与窗口，current 由前端传本机 device_id 判定）
create or replace function public.my_devices(p_device text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_win int;
  v_limit int;
  v_list jsonb;
begin
  if v_me is null then raise exception '请先登录'; end if;
  v_win   := public.cfg_int('device_window_days', 45);
  v_limit := public.cfg_int('device_limit', 3);
  select coalesce(jsonb_agg(jsonb_build_object(
           'device_id', device_id,
           'ua', ua,
           'last_seen', last_seen,
           'current', (device_id = coalesce(p_device, ''))
         ) order by last_seen desc nulls last), '[]'::jsonb)
    into v_list
    from public.devices
   where uid = v_me
     and not coalesce(revoked, false)
     and last_seen > now() - (v_win || ' days')::interval;

  return jsonb_build_object('ok', true, 'limit', v_limit, 'window_days', v_win, 'devices', v_list);
end $$;
grant execute on function public.my_devices(text) to authenticated;

-- 2) 解绑：明确告诉调用方是否真的解绑到了
create or replace function public.unbind_device(p_device text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_hit int := 0;
begin
  if v_me is null then raise exception '请先登录'; end if;
  if coalesce(trim(p_device), '') = '' then raise exception '设备标识为空'; end if;
  update public.devices set revoked = true, last_seen = now()
   where uid = v_me and device_id = p_device and not coalesce(revoked, false);
  get diagnostics v_hit = row_count;
  return jsonb_build_object('ok', v_hit > 0, 'count', v_hit);
end $$;
grant execute on function public.unbind_device(text) to authenticated;

-- 3) 记录迁移
insert into public.migration_probe (id, at) values (3, now())
on conflict (id) do update set at = excluded.at;
