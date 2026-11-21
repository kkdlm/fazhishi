create or replace function public.log_meta(p_act text)
returns table(label text, vis text, keys text[])
language sql immutable as $$
  select '登录'::text, 'self'::text, '{}'::text[]
$$;
insert into public.migration_probe (id, at) values (12, now()) on conflict (id) do update set at = excluded.at;
