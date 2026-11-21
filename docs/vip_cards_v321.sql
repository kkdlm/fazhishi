-- 法制史一点通 · v3.20.0 补丁 1 数据库增量（第 11 段，幂等）
-- 修复：register_device 允许调用方自带 p_limit 覆盖设备上限，任何人都能传 999 绕过设备限制。
-- 现在上限只从 app_config 读；仅管理员可临时指定 p_limit。

create or replace function public.register_device(p_device text, p_ua text default null, p_limit int default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_known boolean; v_n int; v_list jsonb;
        v_limit int; v_win int;
begin
  if v_me is null then raise exception '请先登录'; end if;
  if coalesce(trim(p_device),'') = '' then raise exception '设备标识为空'; end if;
  v_limit := public.cfg_int('device_limit', 3);
  v_win   := public.cfg_int('device_window_days', 45);
  -- 只有管理员可以临时指定上限，普通用户传什么都不生效
  if coalesce(p_limit,0) > 0 and public.is_admin() then v_limit := p_limit; end if;

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
