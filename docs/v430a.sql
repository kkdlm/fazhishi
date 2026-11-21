-- 4.0.3 日志：第 1 段（建表）—— 仅为定位失败点，跑通后删除本文件
create table if not exists public.activity_log (
  id         bigserial primary key,
  uid        uuid,
  action     text not null,
  target     text,
  detail     jsonb not null default '{}'::jsonb,
  vis        text not null default 'self',
  created_at timestamptz not null default now()
);
create index if not exists act_uid_idx  on public.activity_log(uid, created_at desc);
create index if not exists act_time_idx on public.activity_log(created_at desc);
alter table public.activity_log enable row level security;

insert into public.migration_probe (id, at) values (8, now())
on conflict (id) do update set at = excluded.at;
