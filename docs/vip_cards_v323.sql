-- v3.20.0 补丁 3：邀请码生成的兜底（幂等）
-- 1) 确保 profiles.invite_code 列与唯一索引存在
alter table public.profiles add column if not exists invite_code text;
create unique index if not exists profiles_invite_code_uidx
  on public.profiles (upper(invite_code)) where invite_code is not null;

-- 2) 生成邀请码前先确保 profiles 有这一行（新注册未建档时也能拿到码）
create or replace function public.ensure_invite_code()
returns text language plpgsql security definer set search_path = public as $$
declare v text; i int; me uuid := auth.uid();
begin
  if me is null then raise exception '请先登录'; end if;
  insert into public.profiles(uid) values (me) on conflict (uid) do nothing;

  select invite_code into v from public.profiles where uid = me;
  if v is not null and v <> '' then return v; end if;

  for i in 1..8 loop
    v := 'FZ' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
    begin
      update public.profiles set invite_code = v
       where uid = me and coalesce(invite_code, '') = '';
      if found then return v; end if;
      select invite_code into v from public.profiles where uid = me;
      if v is not null and v <> '' then return v; end if;
      v := null;
    exception when unique_violation then
      v := null;
    end;
  end loop;

  raise exception '邀请码生成失败，稍后再试';
end $$;
grant execute on function public.ensure_invite_code() to authenticated;
