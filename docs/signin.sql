-- ============================================================
-- 法制史一点通 · 每日签到（服务端记账，跨设备）
-- 由 .github/workflows/db.yml 在 push 本文件时自动整段执行（幂等，可重复跑）。
-- 说明：
--   · 签到按「账号 + 北京时间当天」唯一，一天只能签一次
--   · 连续满 7 天送 3 天会员，第 14、21… 天同样送 3 天
--   · 会员天数直接写进 profiles.pro_until（客户端没有写权限，只能走这个函数）
-- 文件变更时间 2026-11-22：补齐到仓库，让 CI 真正执行
-- ============================================================

-- 1) 签到流水表
create table if not exists public.sign_ins (
  uid        uuid        not null,
  day        date        not null,
  seq        int         not null default 1,   -- 当天是连续第几天
  gift_days  int         not null default 0,   -- 当天送出的会员天数
  created_at timestamptz not null default now(),
  primary key (uid, day)
);
create index if not exists sign_ins_day_idx on public.sign_ins (day desc);

-- 2) 只读自己的签到记录；写入全部走下面的函数
alter table public.sign_ins enable row level security;
drop policy if exists sign_ins_self_read on public.sign_ins;
create policy sign_ins_self_read on public.sign_ins
  for select using (auth.uid() = uid);

-- 3) 签到
create or replace function public.sign_in()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$declare
  v_uid        uuid := auth.uid();
  v_today      date := (now() at time zone 'Asia/Shanghai')::date;
  v_seq        int  := 0;
  v_gift       int  := 0;
  v_total      int  := 0;
  v_gift_total int  := 0;
  v_until      timestamptz;
  v_type       text;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'NOAUTH', 'msg', '未登录');
  end if;

  if exists (select 1 from sign_ins where uid = v_uid and day = v_today) then
    return jsonb_build_object('ok', false, 'code', 'DONE', 'msg', '今天已经签过了');
  end if;

  -- 昨天签过就 +1，否则从 1 重算
  select coalesce(max(seq), 0) + 1 into v_seq
    from sign_ins where uid = v_uid and day = v_today - 1;
  if v_seq = 0 or v_seq is null then v_seq := 1; end if;

  if v_seq % 7 = 0 then v_gift := 3; end if;

  insert into sign_ins (uid, day, seq, gift_days)
    values (v_uid, v_today, v_seq, v_gift)
    on conflict (uid, day) do nothing;

  select count(*), coalesce(sum(gift_days), 0) into v_total, v_gift_total
    from sign_ins where uid = v_uid;

  if v_gift > 0 then
    select data_type into v_type from information_schema.columns
      where table_schema = 'public' and table_name = 'profiles' and column_name = 'pro_until';
    if v_type like 'timestamp%' then
      update profiles
         set pro_until = greatest(coalesce(pro_until, now()), now()) + make_interval(days => v_gift)
       where uid = v_uid;
    else
      update profiles
         set pro_until = greatest(coalesce(pro_until, current_date), current_date) + v_gift
       where uid = v_uid;
    end if;
  end if;

  select pro_until::timestamptz into v_until from profiles where uid = v_uid;

  return jsonb_build_object(
    'ok', true, 'day', v_today, 'seq', v_seq,
    'total', v_total, 'gift', v_gift, 'gift_total', v_gift_total,
    'until', v_until
  );
end $$;

grant execute on function public.sign_in() to authenticated;

-- 4) 查询签到状态（进「我的」页时拉一次）
create or replace function public.sign_in_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$declare
  v_uid   uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Shanghai')::date;
  v_seq   int  := 0;
  v_total int  := 0;
  v_gift  int  := 0;
  v_last  date;
  v_until timestamptz;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'NOAUTH');
  end if;

  select count(*), coalesce(sum(gift_days), 0) into v_total, v_gift
    from sign_ins where uid = v_uid;

  select day, seq into v_last, v_seq
    from sign_ins where uid = v_uid order by day desc limit 1;

  if v_last is null or v_last < v_today - 1 then v_seq := 0; end if;

  select pro_until::timestamptz into v_until from profiles where uid = v_uid;

  return jsonb_build_object(
    'ok', true, 'day', v_last, 'seq', coalesce(v_seq, 0),
    'total', v_total, 'gift_total', v_gift, 'until', v_until,
    'today', v_today
  );
end $$;

grant execute on function public.sign_in_status() to authenticated;

-- 完成：App →「我的」→ 会员卡下方签到卡，天数与赠送跨设备同一份。
