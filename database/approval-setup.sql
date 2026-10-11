begin;

create table if not exists public.ogawa_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.ogawa_admins enable row level security;
revoke all on public.ogawa_admins from anon, authenticated;
grant select on public.ogawa_admins to authenticated;
drop policy if exists "管理者が自分の登録を確認" on public.ogawa_admins;
create policy "管理者が自分の登録を確認" on public.ogawa_admins
for select to authenticated using (user_id = (select auth.uid()));

-- 既に編集権限を設定した所有者だけを初期管理者にする。
insert into public.ogawa_admins(user_id)
select m.user_id from public.ogawa_members m
where m.user_id = 'd5fcfeaa-6f5d-42f8-8cfd-7a490e05ad44'::uuid
  and m.role = 'editor'
on conflict do nothing;
do $$ begin
  if not exists(select 1 from public.ogawa_admins
    where user_id = 'd5fcfeaa-6f5d-42f8-8cfd-7a490e05ad44'::uuid) then
    raise exception '初期管理者が見つかりません。ユーザーUIDを確認してください。';
  end if;
end $$;

create table if not exists public.ogawa_access_requests (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  display_name text not null,
  job text not null check (job in ('店長','育成担当')),
  status text not null default 'pending' check(status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id)
);
alter table public.ogawa_access_requests enable row level security;
revoke all on public.ogawa_access_requests from anon, authenticated;
grant select on public.ogawa_access_requests to authenticated;
drop policy if exists "本人と管理者が申請を確認" on public.ogawa_access_requests;
create policy "本人と管理者が申請を確認" on public.ogawa_access_requests
for select to authenticated using (
  user_id = (select auth.uid()) or exists (
    select 1 from public.ogawa_admins where user_id = (select auth.uid())
  )
);

create or replace function public.ogawa_request_access()
returns text language plpgsql security definer set search_path = '' as $$
declare
  applicant auth.users%rowtype;
  request_status text;
  applicant_job text;
begin
  if auth.uid() is null then raise exception 'ログインしてください'; end if;
  select * into applicant from auth.users where id = auth.uid();
  if applicant.email_confirmed_at is null then
    raise exception '確認メールで本人確認してください';
  end if;
  if exists(select 1 from public.ogawa_members where user_id = auth.uid()) then
    return 'approved';
  end if;
  applicant_job := applicant.raw_user_meta_data->>'job';
  if applicant_job is null or applicant_job not in ('店長','育成担当') then
    raise exception '登録時に店長または育成担当を選んでください';
  end if;
  insert into public.ogawa_access_requests(user_id,email,display_name,job)
  values(auth.uid(),applicant.email,
    left(coalesce(nullif(trim(applicant.raw_user_meta_data->>'display_name'),''),'名前未設定'),80),
    applicant_job)
  on conflict(user_id) do nothing;
  select status into request_status from public.ogawa_access_requests where user_id = auth.uid();
  return request_status;
end $$;
revoke all on function public.ogawa_request_access() from public, anon;
grant execute on function public.ogawa_request_access() to authenticated;

create or replace function public.ogawa_review_access(target_user uuid, approve boolean)
returns text language plpgsql security definer set search_path = '' as $$
declare request_row public.ogawa_access_requests%rowtype;
begin
  if not exists(select 1 from public.ogawa_admins where user_id = auth.uid()) then
    raise exception '承認は管理者のみ行えます';
  end if;
  if approve is null then raise exception '承認結果が必要です'; end if;
  select * into request_row from public.ogawa_access_requests
    where user_id = target_user for update;
  if not found or request_row.status <> 'pending' then
    raise exception 'この申請は既に処理済みです';
  end if;
  if approve then
    if not exists(select 1 from auth.users where id = target_user and email_confirmed_at is not null) then
      raise exception 'メール確認が完了していません';
    end if;
    insert into public.ogawa_members(user_id,role) values(target_user,'editor')
    on conflict(user_id) do update set role = 'editor';
  end if;
  update public.ogawa_access_requests
    set status = case when approve then 'approved' else 'rejected' end,
        reviewed_at = now(), reviewed_by = auth.uid()
    where user_id = target_user;
  return case when approve then 'approved' else 'rejected' end;
end $$;
revoke all on function public.ogawa_review_access(uuid,boolean) from public, anon;
grant execute on function public.ogawa_review_access(uuid,boolean) to authenticated;
commit;
