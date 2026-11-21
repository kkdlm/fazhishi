-- v3.21.0 后台：清空某个用户的学习数据（不清会员、不删账号）
-- 幂等：可重复执行

create or replace function public.admin_purge_user(p_uid uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_prog int := 0; v_dev int := 0; v_free int := 0; v_ref int := 0;
begin
  if not public.is_admin() then raise exception '需要管理员权限'; end if;
  if p_uid is null then raise exception '缺少用户 uid'; end if;

  delete from public.progress   where uid = p_uid;
  get diagnostics v_prog = row_count;

  delete from public.devices    where uid = p_uid;
  get diagnostics v_dev = row_count;

  delete from public.free_usage where uid = p_uid;
  get diagnostics v_free = row_count;

  delete from public.referrals  where inviter = p_uid or invitee = p_uid;
  get diagnostics v_ref = row_count;

  insert into public.audit_log(actor, action, target, detail)
    values (auth.uid(), 'purge_user', p_uid::text,
            jsonb_build_object('progress', v_prog, 'devices', v_dev,
                               'free_usage', v_free, 'referrals', v_ref));

  return jsonb_build_object('ok', true, 'progress', v_prog, 'devices', v_dev,
                            'free_usage', v_free, 'referrals', v_ref);
end $$;
grant execute on function public.admin_purge_user(uuid) to authenticated;

insert into public.migration_probe (id, at) values (5, now())
on conflict (id) do update set at = excluded.at;
