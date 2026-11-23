-- ============ 活动：抽奖（v1.2.0.5 起；奖项可配见 v1.2.0.6） ============
-- 玩法：每天签到的次数「只当天有效」，过了零点清零；邀请好友注册得到的次数「可累积」。
-- 奖项与概率由后台「活动 · 抽奖」页配置，存在 app_config.lottery_prizes（jsonb 数组）。
-- 两个池分别算（服务端唯一口径，前端只读）：
--   今日签到池 = 今天签过 ? lottery_sign_tickets : 0  − 今天已用掉的签到次数
--   累积邀请池 = 邀请成功人数 × lottery_invite_tickets − 已用掉的邀请次数
-- 抽奖时优先扣当天到期的签到次数，扣完才用累积的。

create table if not exists public.lottery_draws (
  id           bigserial   primary key,
  uid          uuid        not null,
  prize        text        not null,              -- 奖项标识（后台配置里的 k）
  days         int         not null default 0,    -- 本次实际加的会员天数
  used_ticket  boolean     not null default true, -- 「再来一次」为 false，不扣次数
  created_at   timestamptz not null default now()
);
alter table public.lottery_draws add column if not exists ticket_src text;  -- 'sign' 当天签到 / 'invite' 累积 / null 未扣
alter table public.lottery_draws add column if not exists draw_day  date;  -- 抽奖当天（北京时间），用于清当天签到的次数
create index if not exists lottery_draws_uid_idx on public.lottery_draws (uid, created_at desc);

alter table public.lottery_draws enable row level security;
drop policy if exists lottery_self_read on public.lottery_draws;
create policy lottery_self_read on public.lottery_draws
  for select using (auth.uid() = uid);
revoke insert, update, delete on public.lottery_draws from anon, authenticated;

-- 奖项池：后台没配 / 配坏了就用这份默认（8 格，与旧版转盘一致）
create or replace function public.lottery_prizes()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  select val into v from public.app_config where key = 'lottery_prizes';
  if v is null or jsonb_typeof(v) <> 'array' or jsonb_array_length(v) < 2 then
    v := '[
      {"k":"vip1", "name":"会员 1 天", "kind":"vip",   "days":1,  "w":26},
      {"k":"again", "name":"再来一次",  "kind":"again", "days":0,  "w":13},
      {"k":"vip3", "name":"会员 3 天", "kind":"vip",   "days":3,  "w":12},
      {"k":"none", "name":"谢谢参与",  "kind":"none",  "days":0,  "w":15},
      {"k":"vip7", "name":"会员 7 天", "kind":"vip",   "days":7,  "w":5},
      {"k":"again2","name":"再来一次", "kind":"again", "days":0,  "w":13},
      {"k":"vip1b","name":"会员 1 天", "kind":"vip",   "days":1,  "w":26},
      {"k":"vip30","name":"会员 30 天","kind":"vip",   "days":30, "w":1}
    ]'::jsonb;
  end if;
  return v;
end $$;
grant execute on function public.lottery_prizes() to authenticated;

-- 北京时间「今天」
create or replace function public.lottery_today()
returns date language sql stable set search_path = public as $$
  select (now() at time zone 'Asia/Shanghai')::date;
$$;
grant execute on function public.lottery_today() to authenticated;

-- 签到池：只在今天有效（今天签过才有，扣掉今天用掉的）
create or replace function public.lottery_sign_left()
returns int language sql stable security definer set search_path = public as $$
  select greatest(0,
      (case when exists (
          select 1 from public.sign_ins s
           where s.uid = auth.uid() and s.day = public.lottery_today())
       then public.cfg_int('lottery_sign_tickets', 1) else 0 end)
    - (select count(*) from public.lottery_draws d
        where d.uid = auth.uid() and d.ticket_src = 'sign'
          and d.draw_day = public.lottery_today())::int
  );
$$;
grant execute on function public.lottery_sign_left() to authenticated;

-- 累积池：邀请成功的人次换来的次数，永不过期
create or replace function public.lottery_invite_left()
returns int language sql stable security definer set search_path = public as $$
  select greatest(0,
      (select count(*) from public.referrals r where r.inviter = auth.uid())::int
        * public.cfg_int('lottery_invite_tickets', 1)
    - (select count(*) from public.lottery_draws d
        where d.uid = auth.uid() and d.ticket_src = 'invite')::int
  );
$$;
grant execute on function public.lottery_invite_left() to authenticated;

-- 我手上还有几次（两个池加起来）
create or replace function public.lottery_tickets()
returns int language sql stable security definer set search_path = public as $$
  select public.lottery_sign_left() + public.lottery_invite_left();
$$;
grant execute on function public.lottery_tickets() to authenticated;

-- 抽奖页要的全部状态：次数、奖项池、最近一次
create or replace function public.lottery_status()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_last jsonb;
begin
  if v_me is null then return jsonb_build_object('ok', false, 'msg', '请先登录'); end if;
  select jsonb_build_object('prize', prize, 'days', days, 'at', created_at)
    into v_last from public.lottery_draws
   where uid = v_me order by id desc limit 1;
  return jsonb_build_object(
    'ok',         true,
    'on',         public.cfg_bool('lottery_enabled', true),
    'tickets',    public.lottery_tickets(),          -- 总共可用
    'sign',       public.lottery_sign_left(),         -- 今天签到的、当天有效
    'invite',     public.lottery_invite_left(),       -- 邀请攒下的、可累积
    'sign_per',   public.cfg_int('lottery_sign_tickets', 1),
    'invite_per', public.cfg_int('lottery_invite_tickets', 1),
    'signed',     (exists (select 1 from public.sign_ins s where s.uid = v_me and s.day = public.lottery_today())),
    'total',      (select count(*) from public.lottery_draws where uid = v_me),
    'prizes',     public.lottery_prizes(),
    'last',       v_last,
    'until',      (select pro_until from public.profiles where uid = v_me)
  );
end $$;
grant execute on function public.lottery_status() to authenticated;

-- 转一次：按后台配置的权重抽，返回选中的是第几格（前端据此停格）
create or replace function public.lottery_draw()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_s int; v_i int; v_src text; v_left int;
  v_prizes jsonb; v_n int; v_total numeric := 0; v_r numeric; v_cum numeric := 0;
  v_idx int := 0; v_item jsonb; v_w numeric;
  v_prize text; v_kind text; v_days int; v_name text; v_until timestamptz;
  i int;
begin
  if v_me is null then raise exception '请先登录'; end if;
  if not public.cfg_bool('lottery_enabled', true) then
    return jsonb_build_object('ok', false, 'msg', '抽奖活动暂时关闭');
  end if;

  v_s := public.lottery_sign_left();
  v_i := public.lottery_invite_left();
  if v_s + v_i <= 0 then
    return jsonb_build_object('ok', false, 'msg', '今天的次数用完了，明天签到再来');
  end if;

  v_prizes := public.lottery_prizes();
  v_n := jsonb_array_length(v_prizes);
  for i in 0..(v_n - 1) loop
    v_total := v_total + greatest(0, coalesce((v_prizes -> i ->> 'w')::numeric, 0));
  end loop;
  if v_total <= 0 then
    return jsonb_build_object('ok', false, 'msg', '奖项还没配好，稍后再来');
  end if;

  v_r := random() * v_total;
  for i in 0..(v_n - 1) loop
    v_item := v_prizes -> i;
    v_w := greatest(0, coalesce((v_item ->> 'w')::numeric, 0));
    v_cum := v_cum + v_w;
    if v_r < v_cum then v_idx := i; exit; end if;
    v_idx := i;
  end loop;

  v_item := v_prizes -> v_idx;
  v_prize := coalesce(v_item ->> 'k', 'prize');
  v_kind  := coalesce(v_item ->> 'kind', 'none');
  v_days  := greatest(0, coalesce((v_item ->> 'days')::int, 0));
  v_name  := coalesce(v_item ->> 'name', '谢谢参与');
  if v_kind <> 'vip' then v_days := 0; end if;

  /* 扣哪一边：再来一次不扣；其余先扣当天到期的签到次数，扣完才用累积的邀请次数 */
  if v_kind = 'again' then v_src := null;
  elsif v_s > 0 then v_src := 'sign';
  else v_src := 'invite';
  end if;
  insert into public.lottery_draws (uid, prize, days, used_ticket, ticket_src, draw_day)
    values (v_me, v_prize, v_days, v_kind <> 'again', v_src, public.lottery_today());

  if v_days > 0 then
    update public.profiles
       set pro_until = greatest(coalesce(pro_until, now()), now()) + (v_days || ' days')::interval
     where uid = v_me
     returning pro_until into v_until;
  else
    select pro_until into v_until from public.profiles where uid = v_me;
  end if;

  v_left := public.lottery_tickets();

  return jsonb_build_object(
    'ok', true, 'idx', v_idx, 'prize', v_prize, 'name', v_name, 'kind', v_kind,
    'days', v_days, 'until', v_until, 'tickets', v_left, 'free', (v_kind = 'again'),
    'sign', public.lottery_sign_left(), 'invite', public.lottery_invite_left()
  );
end $$;
grant execute on function public.lottery_draw() to authenticated;

-- 最近中奖流水（最多 20 条）
create or replace function public.lottery_log()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select prize, days, used_ticket, ticket_src, created_at
      from public.lottery_draws
     where uid = auth.uid()
     order by id desc limit 20
  ) x;
$$;
grant execute on function public.lottery_log() to authenticated;
