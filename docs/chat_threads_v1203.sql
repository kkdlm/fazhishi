-- 后台会话列表：补一个「最后一条消息类型」，用于识别用户已点「我已转账、等卡密」的会话
-- 幂等：只替换函数，不改表结构；可重复执行
create or replace function admin_chat_threads()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare arr json;
begin
  if not chat_is_admin() then raise exception 'not admin'; end if;
  select json_agg(t) into arr from (
    select p.uid,
           p.email,
           p.nickname as nick,
           p.ip_prov,
           p.ip_city,
           p.last_seen,
           p.pro_until,
           coalesce(max(m.id), 0)                                    as last_id,
           (array_agg(m.body order by m.id desc) filter (where m.id is not null))[1] as last_body,
           (array_agg(m.role order by m.id desc) filter (where m.id is not null))[1] as last_role,
           (array_agg(m.kind order by m.id desc) filter (where m.id is not null))[1] as last_kind,
           max(m.created_at)                                          as last_at,
           coalesce(sum(case when m.role = 'user' and m.seen_admin = false then 1 else 0 end), 0)::int as unread,
           (max(m.id) is not null)                                    as has_msg
      from profiles p
      left join support_msgs m on m.uid = p.uid
     group by p.uid, p.email, p.nickname, p.ip_prov, p.ip_city, p.last_seen, p.pro_until
     order by coalesce(sum(case when m.role = 'user' and m.seen_admin = false then 1 else 0 end), 0) desc,
              coalesce((array_agg(m.kind order by m.id desc) filter (where m.id is not null))[1] = 'paid', false) desc,
              coalesce(max(m.id), 0) desc,
              p.last_seen desc nulls last
     limit 500
  ) t;
  return coalesce(arr, '[]'::json);
end $$;

grant execute on function admin_chat_threads() to authenticated;
