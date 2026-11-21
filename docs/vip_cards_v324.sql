-- v3.21.0：非会员每日背诵额度改为服务端计数（幂等）
create table if not exists public.free_usage (
  uid uuid not null,
  day date not null,
  item text not null,
  created_at timestamptz not null default now(),
  primary key (uid, day, item)
);
alter table public.free_usage enable row level security;
revoke all on public.free_usage from anon, authenticated;

create or replace function public.free_bk_take(p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); lim int; used int; dup boolean;
begin
  if me is null then raise exception '请先登录'; end if;
  lim := greatest(1, least(50, public.cfg_int('free_bk_limit', 5)));
  select exists(select 1 from public.free_usage
                 where uid = me and day = current_date and item = p_key) into dup;
  select count(*) into used from public.free_usage where uid = me and day = current_date;
  if dup then
    return jsonb_build_object('ok', true, 'used', used, 'limit', lim, 'dup', true);
  end if;
  if used >= lim then
    return jsonb_build_object('ok', false, 'used', used, 'limit', lim);
  end if;
  insert into public.free_usage(uid, day, item) values (me, current_date, p_key)
    on conflict do nothing;
  select count(*) into used from public.free_usage where uid = me and day = current_date;
  return jsonb_build_object('ok', true, 'used', used, 'limit', lim);
end $$;
grant execute on function public.free_bk_take(text) to authenticated;

create or replace function public.free_bk_state()
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); lim int; used int;
begin
  if me is null then raise exception '请先登录'; end if;
  lim := greatest(1, least(50, public.cfg_int('free_bk_limit', 5)));
  select count(*) into used from public.free_usage where uid = me and day = current_date;
  return jsonb_build_object('used', used, 'limit', lim);
end $$;
grant execute on function public.free_bk_state() to authenticated;
