-- A SECURITY DEFINER view is easy to widen accidentally. Materialize the
-- deliberately public projection instead, and keep it synchronized by a
-- non-callable trigger.

drop view if exists public.profile_directory;

create table public.profile_directory (
  id uuid primary key references public.profiles(id) on delete cascade,
  username text,
  full_name text,
  avatar_url text,
  bio text,
  website text,
  created_at timestamptz,
  updated_at timestamptz,
  account_type varchar,
  id_num bigint,
  banner_url text
);

alter table public.profile_directory enable row level security;
create policy profile_directory_public_read
on public.profile_directory
for select
to anon, authenticated
using (true);

revoke all privileges on table public.profile_directory from public, anon, authenticated;
grant select on table public.profile_directory to anon, authenticated;

insert into public.profile_directory (
  id,
  username,
  full_name,
  avatar_url,
  bio,
  website,
  created_at,
  updated_at,
  account_type,
  id_num,
  banner_url
)
select
  id,
  username,
  full_name,
  avatar_url,
  bio,
  website,
  created_at,
  updated_at,
  account_type,
  id_num,
  banner_url
from public.profiles
where visibility = 'public';

create or replace function public.sync_profile_directory()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    delete from public.profile_directory where id = old.id;
    return old;
  end if;

  if new.visibility <> 'public' then
    delete from public.profile_directory where id = new.id;
    return new;
  end if;

  insert into public.profile_directory (
    id,
    username,
    full_name,
    avatar_url,
    bio,
    website,
    created_at,
    updated_at,
    account_type,
    id_num,
    banner_url
  ) values (
    new.id,
    new.username,
    new.full_name,
    new.avatar_url,
    new.bio,
    new.website,
    new.created_at,
    new.updated_at,
    new.account_type,
    new.id_num,
    new.banner_url
  )
  on conflict (id) do update set
    username = excluded.username,
    full_name = excluded.full_name,
    avatar_url = excluded.avatar_url,
    bio = excluded.bio,
    website = excluded.website,
    created_at = excluded.created_at,
    updated_at = excluded.updated_at,
    account_type = excluded.account_type,
    id_num = excluded.id_num,
    banner_url = excluded.banner_url;
  return new;
end;
$$;

revoke all on function public.sync_profile_directory() from public, anon, authenticated;

create trigger sync_profile_directory
after insert or update or delete on public.profiles
for each row execute function public.sync_profile_directory();

alter function public.log_profiles_change() set search_path = '';
revoke all on function public.log_profiles_change() from public, anon, authenticated;
revoke all on function public.handle_new_user_profile() from public, anon, authenticated;
revoke all on function public.protect_profile_privileged_fields() from public, anon, authenticated;
