-- 链路探针：验证 docs/*.sql push 后由 db-migrate 自动执行（每次推送插入 id=2 刷新时间）
-- 看到 id=2 的 at 是最近时间，说明自动迁移真的在跑；没有则是 secret 未生效。
insert into public.migration_probe(id) values (2) on conflict (id) do update set at = now();
