create or replace function public.mylogs_probe(p_limit int default 30, p_offset int default 0, p_act text default null)
returns table(id bigint, act text, label text, target text, detail jsonb, at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '需要登录'; end if;
  return query select 1::bigint, 'login'::text, '登录'::text, null::text, '{}'::jsonb, now();
end $$;
grant execute on function public.mylogs_probe(int, int, text) to authenticated;
insert into public.migration_probe (id, at) values (13, now()) on conflict (id) do update set at = excluded.at;
