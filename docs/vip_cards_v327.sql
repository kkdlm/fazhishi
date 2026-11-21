-- v3.21.0 用户系统完善（2）：自助注销账号
-- 口径：立即清掉学习数据与设备/邀请关系，账号标记停用；不删 auth.users 行（需 service_role，由管理员在后台清理邮箱）
-- 幂等：可重复执行

alter table public.profiles add column if not exists delete_requested_at timestamptz;

create or replace function public.request_account_delete()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid();
begin
  if v_me is null then raise exception '请先登录'; end if;

  delete from public.progress   where uid = v_me;
  delete from public.devices    where uid = v_me;
  delete from public.free_usage where uid = v_me;
  delete from public.referrals  where inviter = v_me or invitee = v_me;

  update public.profiles
     set banned = true,
         delete_requested_at = now(),
         pro_until = null
   where uid = v_me;

  return jsonb_build_object('ok', true, 'msg', '学习数据已清空，账号已停用');
end $$;
grant execute on function public.request_account_delete() to authenticated;

insert into public.migration_probe (id, at) values (4, now())
on conflict (id) do update set at = excluded.at;
