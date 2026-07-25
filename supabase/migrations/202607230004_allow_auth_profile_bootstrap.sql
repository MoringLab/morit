-- Auth creates the initial profile from an auth.users AFTER INSERT trigger.
-- That trusted nested trigger has no end-user JWT, so allow only a default,
-- matching row that already exists in auth.users.

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

  if tg_op = 'INSERT'
     and actor_id is null
     and pg_trigger_depth() > 1
     and new.permission_level = 5
     and new.account_type = 'general'
     and exists (
       select 1
       from auth.users as u
       where u.id = new.id
         and u.email is not distinct from new.email
     ) then
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

create or replace function public.handle_new_user_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, created_at, updated_at)
  values (new.id, new.email, now(), now());
  return new;
end;
$$;
