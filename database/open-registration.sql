begin;
create table if not exists public.ogawa_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.ogawa_admins enable row level security;
revoke all on public.ogawa_admins from anon, authenticated;
grant select on public.ogawa_admins to authenticated;
drop policy if exists "管理者が自分の登録を確認" on public.ogawa_admins;
create policy "管理者が自分の登録を確認" on public.ogawa_admins
for select to authenticated using(user_id = (select auth.uid()));

insert into public.ogawa_admins(user_id)
select user_id from public.ogawa_members
where user_id = 'd5fcfeaa-6f5d-42f8-8cfd-7a490e05ad44'::uuid and role = 'editor'
on conflict do nothing;
do $$ begin
  if not exists(select 1 from public.ogawa_admins
    where user_id = 'd5fcfeaa-6f5d-42f8-8cfd-7a490e05ad44'::uuid) then
    raise exception 'あなたの管理者登録が見つかりません。ユーザーUIDを確認してください。';
  end if;
end $$;

-- 本人確認済みの登録者は全員編集用。未ログイン・削除済みユーザーは不可。
create or replace function public.ogawa_request_access()
returns text language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'ログインしてください'; end if;
  if not exists(select 1 from auth.users
    where id = auth.uid() and email_confirmed_at is not null) then
    raise exception '確認メールで本人確認してください';
  end if;
  insert into public.ogawa_members(user_id,role) values(auth.uid(),'editor')
  on conflict(user_id) do update set role = 'editor';
  return 'approved';
end $$;
revoke all on function public.ogawa_request_access() from public, anon;
grant execute on function public.ogawa_request_access() to authenticated;
update public.ogawa_members m set role = 'editor'
where exists(select 1 from auth.users u where u.id = m.user_id and u.email_confirmed_at is not null);

create or replace function public.ogawa_registered_users()
returns table(user_id uuid,email text,display_name text,job text,is_admin boolean,email_confirmed boolean,created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not exists(select 1 from public.ogawa_admins where ogawa_admins.user_id = auth.uid()) then
    raise exception '登録者一覧は管理者のみ確認できます';
  end if;
  return query select u.id,u.email::text,
    coalesce(nullif(u.raw_user_meta_data->>'display_name',''),u.email)::text,
    coalesce(u.raw_user_meta_data->>'job','未設定')::text,
    exists(select 1 from public.ogawa_admins a where a.user_id=u.id),
    u.email_confirmed_at is not null,u.created_at
  from auth.users u order by u.created_at;
end $$;
revoke all on function public.ogawa_registered_users() from public, anon;
grant execute on function public.ogawa_registered_users() to authenticated;

create or replace function public.ogawa_delete_registered_user(target_user uuid)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if not exists(select 1 from public.ogawa_admins where user_id=auth.uid()) then
    raise exception '登録者の削除は管理者のみ行えます';
  end if;
  if target_user is null or target_user=auth.uid()
    or exists(select 1 from public.ogawa_admins where user_id=target_user) then
    raise exception 'あなた自身や管理者は削除できません';
  end if;
  if not exists(select 1 from auth.users where id=target_user) then
    raise exception 'この登録者は既に削除されています';
  end if;
  -- 旧承認方式を設定済みの場合の履歴参照を整理。
  if pg_catalog.to_regclass('public.ogawa_access_requests') is not null then
    execute 'update public.ogawa_access_requests set reviewed_by=null where reviewed_by=$1' using target_user;
    execute 'delete from public.ogawa_access_requests where user_id=$1' using target_user;
  end if;
  delete from public.ogawa_members where user_id=target_user;
  delete from auth.users where id=target_user;
  return 'deleted';
end $$;
revoke all on function public.ogawa_delete_registered_user(uuid) from public, anon;
grant execute on function public.ogawa_delete_registered_user(uuid) to authenticated;
-- 旧承認操作を無効化。
do $$ begin
  if pg_catalog.to_regprocedure('public.ogawa_review_access(uuid,boolean)') is not null then
    execute 'revoke execute on function public.ogawa_review_access(uuid,boolean) from authenticated';
  end if;
end $$;
commit;
