-- 收尾授权：db.yml 按文件名顺序执行 docs/*.sql，
-- 而 vip_cards_v324.sql 里有一句 revoke all on public.free_usage from anon, authenticated，
-- 会把我前面 grant 的读权限再撤销掉。文件名用 zz_ 开头保证最后执行。
-- 只放行"读自己那几行"，写权限仍然只走 RPC，前端不能自己改额度。

grant select on public.free_usage to authenticated;

drop policy if exists free_usage_self on public.free_usage;
create policy free_usage_self on public.free_usage
  for select using (auth.uid() = uid or public.is_admin());
