-- v4.1.0：进度表改为「一科目一行」，为后续民法/刑法/宪法/法理接入做准备
-- 现有数据全部落在 subject='fz'（中国法制史），历史进度不丢

alter table public.progress add column if not exists subject text not null default 'fz';

do $$
declare cname text; has_subj boolean;
begin
  select exists(
    select 1 from pg_constraint c join pg_class t on t.oid=c.conrelid
     where t.relname='progress' and c.contype='p' and pg_get_constraintdef(c.oid) like '%subject%'
  ) into has_subj;
  if not has_subj then
    select c.conname into cname from pg_constraint c join pg_class t on t.oid=c.conrelid
     where t.relname='progress' and c.contype='p' limit 1;
    if cname is not null then
      execute format('alter table public.progress drop constraint %I', cname);
    end if;
    execute 'alter table public.progress add primary key (uid, subject)';
  end if;
end $$;

create index if not exists progress_uid_idx on public.progress (uid);

insert into public.migration_probe(id,at) values (6, now()) on conflict (id) do nothing;
