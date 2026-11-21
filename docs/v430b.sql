-- 4.0.3 日志：第 2 段（动作字典）
create or replace function public.log_meta(p_act text)
returns table(label text, vis text, keys text[])
language sql immutable as $$
  select v.a, v.l, v.s, v.k
    from (values
      ('login',        '登录',            'self' , array['method','device']),
      ('logout',       '退出登录',        'self' , array['device']),
      ('signup',       '注册账号',        'self' , array['method','invited']),
      ('pwd_change',   '修改密码',        'self' , array[]::text[]),
      ('card_redeem',  '兑换卡密',        'self' , array['days','prefix','card_type']),
      ('card_fail',    '兑换失败',        'self' , array['reason','prefix']),
      ('vip_on',       '会员开通 / 续期', 'self' , array['days','until','by']),
      ('device_bind',  '绑定设备',        'self' , array['tail','devices','limit']),
      ('device_unbind','解绑设备',        'self' , array['tail','devices']),
      ('invite_claim', '邀请成功',        'self' , array['days_inviter','days_invitee','who']),
      ('delete_request','申请注销',       'self' , array[]::text[]),
      ('free_quota',   '免费额度用完',    'self' , array['limit']),
      ('sync',         '同步进度',        'admin', array['rev','items'])
    ) v(a,l,s,k)
   where v.a = p_act;
$$;
insert into public.migration_probe (id, at) values (9, now()) on conflict (id) do update set at = excluded.at;
