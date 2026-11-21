-- 4.0.3 日志：动作字典（返回 标签/可见级别/可存字段）
create or replace function public.log_meta(p_act text)
returns table(label text, vis text, keys text[])
language sql immutable as $$
  select
    case p_act
      when 'login'         then '登录'
      when 'logout'        then '退出登录'
      when 'signup'        then '注册账号'
      when 'pwd_change'    then '修改密码'
      when 'card_redeem'   then '兑换卡密'
      when 'card_fail'     then '兑换失败'
      when 'vip_on'        then '会员开通或续期'
      when 'device_bind'   then '绑定设备'
      when 'device_unbind' then '解绑设备'
      when 'invite_claim'  then '邀请成功'
      when 'delete_request' then '申请注销'
      when 'free_quota'    then '免费额度用完'
      when 'pay_click'     then '点击开通会员'
      when 'bug_report'    then '提交问题反馈'
      when 'app_open'      then '打开应用'
      else null
    end,
    case p_act
      when 'sync' then 'admin'
      when 'bug_report' then 'admin'
      else 'self'
    end,
    case p_act
      when 'login'         then '{method,device}'::text[]
      when 'logout'        then '{device}'::text[]
      when 'signup'        then '{method,invited}'::text[]
      when 'card_redeem'   then '{days,card_type}'::text[]
      when 'card_fail'     then '{reason}'::text[]
      when 'vip_on'        then '{days,until}'::text[]
      when 'device_bind'   then '{devices,limit}'::text[]
      when 'device_unbind' then '{devices}'::text[]
      when 'invite_claim'  then '{days_inviter,days_invitee,who}'::text[]
      when 'free_quota'    then '{limit}'::text[]
      when 'bug_report'    then '{kind,text}'::text[]
      else '{}'::text[]
    end
$$;
insert into public.migration_probe (id, at) values (9, now()) on conflict (id) do update set at = excluded.at;
