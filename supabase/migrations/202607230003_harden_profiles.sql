-- The shared profiles table previously exposed every column (including email
-- and birth_date) through a public SELECT policy. Keep the private base table
-- owner-scoped and expose an explicit, PII-free directory for social lookups.

revoke all privileges on table public.profiles from anon;
revoke truncate, references, trigger on table public.profiles from authenticated;
grant select, insert, update, delete on table public.profiles to authenticated;

drop policy if exists "Allow public read access to basic profile info" on public.profiles;
drop policy if exists "Users can insert their own profile" on public.profiles;
drop policy if exists "Users can update their own basic profile" on public.profiles;
drop policy if exists "Moderators can update account_type only" on public.profiles;
drop policy if exists "Admins can fully update lower-level users" on public.profiles;
drop policy if exists "Users or admins can delete profiles" on public.profiles;

create policy profiles_select_own
on public.profiles
for select
to authenticated
using ((select auth.uid()) = id);

create policy profiles_select_moderators
on public.profiles
for select
to authenticated
using (public.get_permission_level((select auth.uid())) >= 20);

create policy profiles_insert_own
on public.profiles
for insert
to authenticated
with check (
  (select auth.uid()) = id
  and permission_level = 5
  and account_type = 'general'
);

create policy profiles_update_own
on public.profiles
for update
to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

create policy profiles_update_moderators
on public.profiles
for update
to authenticated
using (
  (select auth.uid()) <> id
  and public.get_permission_level((select auth.uid())) >= 20
)
with check (public.get_permission_level((select auth.uid())) >= 20);

create policy profiles_delete_own_or_admin
on public.profiles
for delete
to authenticated
using (
  (select auth.uid()) = id
  or public.get_permission_level((select auth.uid())) >= 25
);

create or replace function public.protect_profile_privileged_fields()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  actor_level smallint;
  actor_email text := auth.jwt() ->> 'email';
begin
  if auth.role() = 'service_role' then
    return new;
  end if;
  if actor_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select p.permission_level
  into actor_level
  from public.profiles as p
  where p.id = actor_id;

  if tg_op = 'INSERT' then
    if new.id <> actor_id
       or new.permission_level <> 5
       or new.account_type <> 'general'
       or (actor_email is not null and new.email is distinct from actor_email) then
      raise exception 'profile contains protected values' using errcode = '42501';
    end if;
    return new;
  end if;

  if new.id is distinct from old.id
     or new.id_num is distinct from old.id_num
     or new.created_at is distinct from old.created_at then
    raise exception 'immutable profile identity cannot be changed' using errcode = '42501';
  end if;

  if actor_id = old.id then
    if new.permission_level is distinct from old.permission_level
       or new.account_type is distinct from old.account_type
       or (actor_email is not null and new.email is distinct from actor_email) then
      raise exception 'privileged profile fields cannot be changed by their owner'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if actor_level is null or actor_level < 20 or old.permission_level >= actor_level then
    raise exception 'insufficient profile administration permission'
      using errcode = '42501';
  end if;

  if actor_level < 25 then
    if (to_jsonb(new) - array['account_type', 'updated_at'])
       is distinct from
       (to_jsonb(old) - array['account_type', 'updated_at'])
       or new.account_type in ('partner', 'org') then
      raise exception 'moderators may only change a basic account type'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if new.permission_level > actor_level
     or (actor_level < 30 and new.account_type in ('partner', 'org')) then
    raise exception 'profile administration exceeds actor permission'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke all on function public.protect_profile_privileged_fields() from public;

drop trigger if exists protect_profile_privileged_fields on public.profiles;
create trigger protect_profile_privileged_fields
before insert or update on public.profiles
for each row execute function public.protect_profile_privileged_fields();

-- This is the only anonymous profile surface. It intentionally excludes
-- email, birth_date, permission_level, and all other private/admin fields.
create or replace view public.profile_directory
with (security_barrier = true)
as
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

revoke all privileges on table public.profile_directory from public;
grant select on table public.profile_directory to anon, authenticated;

create or replace function public.get_permission_level(user_id uuid)
returns smallint
language sql
stable
security definer
set search_path = ''
as $$
  select p.permission_level
  from public.profiles as p
  where p.id = user_id;
$$;
