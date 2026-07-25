-- Files belong to memo items. A stable attachment UUID makes retries
-- idempotent, while upload_state exposes recoverable failures without ever
-- storing a device-local path in Postgres.

insert into storage.buckets (id, name, public, file_size_limit)
values ('morit-files', 'morit-files', false, 524288000)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit;

create table if not exists morit.attachments (
  id uuid primary key,
  user_id uuid not null default auth.uid()
    references auth.users(id) on delete cascade,
  item_id uuid not null,
  file_name text not null check (
    char_length(file_name) between 1 and 255
    and file_name !~ '[[:cntrl:]/\\]'
  ),
  mime_type text not null default 'application/octet-stream' check (
    char_length(mime_type) between 3 and 255
    and strpos(mime_type, '/') > 1
    and mime_type !~ '[[:cntrl:]]'
  ),
  size_bytes bigint check (
    size_bytes is null or size_bytes between 0 and 524288000
  ),
  storage_path text not null unique check (
    char_length(storage_path) between 1 and 1024
    and split_part(storage_path, '/', 1) = user_id::text
    and split_part(storage_path, '/', 2) = item_id::text
    and char_length(split_part(storage_path, '/', 3)) > 0
    and storage_path !~ '(^|/)\.\.?(/|$)'
  ),
  upload_state text not null default 'pending' check (
    upload_state in ('pending', 'uploading', 'uploaded', 'failed', 'deleting')
  ),
  last_error text check (
    last_error is null or char_length(last_error) <= 500
  ),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  position integer not null default 0 check (position >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint attachments_item_owner_fkey
    foreign key (user_id, item_id)
    references morit.items (user_id, id)
    on delete cascade
);

create index if not exists attachments_item_position_idx
on morit.attachments (user_id, item_id, position, created_at);

create index if not exists attachments_user_state_idx
on morit.attachments (user_id, upload_state, updated_at desc);

-- Preserve the existing item and object path. The deterministic id makes this
-- backfill safe if an operator has to re-run the statement.
insert into morit.attachments (
  id,
  user_id,
  item_id,
  file_name,
  mime_type,
  size_bytes,
  storage_path,
  upload_state,
  attempt_count,
  position,
  created_at,
  updated_at
)
select
  (
    substr(seed.hash, 1, 8) || '-' ||
    substr(seed.hash, 9, 4) || '-' ||
    substr(seed.hash, 13, 4) || '-' ||
    substr(seed.hash, 17, 4) || '-' ||
    substr(seed.hash, 21, 12)
  )::uuid,
  item.user_id,
  item.id,
  left(
    coalesce(
      nullif(
        regexp_replace(
          regexp_replace(item.storage_path, '^.*/', ''),
          '[[:cntrl:]/\\]',
          '_',
          'g'
        ),
        ''
      ),
      'attachment'
    ),
    255
  ),
  case
    when item.mime_type is not null
      and char_length(item.mime_type) between 3 and 255
      and strpos(item.mime_type, '/') > 1
      and item.mime_type !~ '[[:cntrl:]]'
    then item.mime_type
    else 'application/octet-stream'
  end,
  case
    when item.size_bytes between 0 and 524288000 then item.size_bytes
    else null
  end,
  item.storage_path,
  'uploaded',
  1,
  0,
  item.created_at,
  item.updated_at
from morit.items as item
cross join lateral (
  select md5(
    'morit-legacy-attachment:' ||
    item.user_id::text || ':' ||
    item.id::text || ':' ||
    item.storage_path
  ) as hash
) as seed
where item.storage_path is not null
  and item.kind in ('photo', 'video', 'file')
  and char_length(item.storage_path) between 1 and 1024
  and split_part(item.storage_path, '/', 1) = item.user_id::text
  and split_part(item.storage_path, '/', 2) = item.id::text
  and char_length(split_part(item.storage_path, '/', 3)) > 0
  and item.storage_path !~ '(^|/)\.\.?(/|$)'
on conflict (storage_path) do nothing;

-- Convert legacy file items into memo-with-attachment without changing their
-- identity, visible content, folder, favorite flag, timestamps, or old scalar
-- storage columns. legacy_kind retains the only changed semantic field.
do $$
begin
  if exists (
    select 1
    from pg_trigger
    where tgrelid = 'morit.items'::regclass
      and tgname = 'items_set_updated_at'
      and not tgisinternal
  ) then
    alter table morit.items disable trigger items_set_updated_at;
  end if;
end;
$$;

update morit.items
set metadata = jsonb_set(
      coalesce(metadata, '{}'::jsonb),
      '{legacy_kind}',
      coalesce(metadata -> 'legacy_kind', to_jsonb(kind)),
      true
    ),
    kind = 'memo'
where kind in ('photo', 'video', 'file')
  and exists (
    select 1
    from morit.attachments as attachment
    where attachment.user_id = morit.items.user_id
      and attachment.item_id = morit.items.id
      and attachment.storage_path = morit.items.storage_path
  );

do $$
begin
  if exists (
    select 1
    from pg_trigger
    where tgrelid = 'morit.items'::regclass
      and tgname = 'items_set_updated_at'
      and not tgisinternal
  ) then
    alter table morit.items enable trigger items_set_updated_at;
  end if;
end;
$$;

create or replace function morit.enforce_attachment_memo()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from morit.items as item
    where item.user_id = new.user_id
      and item.id = new.item_id
      and item.kind = 'memo'
  ) then
    raise exception 'attachments require an owned memo item'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function morit.enforce_attachment_memo()
from public, anon, authenticated;

drop trigger if exists attachments_require_memo on morit.attachments;
create trigger attachments_require_memo
before insert or update of user_id, item_id on morit.attachments
for each row execute function morit.enforce_attachment_memo();

drop trigger if exists attachments_set_updated_at on morit.attachments;
create trigger attachments_set_updated_at
before update on morit.attachments
for each row execute function morit.set_updated_at();

-- During a staged rollout, an older APK can still write one scalar file item.
-- Convert that write in the database so it cannot bypass the attachment model.
create or replace function morit.capture_legacy_item_attachment()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  attachment_hash text := md5(
    'morit-legacy-attachment:' ||
    new.user_id::text || ':' ||
    new.id::text || ':' ||
    new.storage_path
  );
  attachment_id uuid;
begin
  attachment_id := (
    substr(attachment_hash, 1, 8) || '-' ||
    substr(attachment_hash, 9, 4) || '-' ||
    substr(attachment_hash, 13, 4) || '-' ||
    substr(attachment_hash, 17, 4) || '-' ||
    substr(attachment_hash, 21, 12)
  )::uuid;

  update morit.items as item
  set metadata = jsonb_set(
        coalesce(item.metadata, '{}'::jsonb),
        '{legacy_kind}',
        coalesce(item.metadata -> 'legacy_kind', to_jsonb(new.kind)),
        true
      ),
      kind = 'memo'
  where item.user_id = new.user_id
    and item.id = new.id;

  insert into morit.attachments (
    id,
    user_id,
    item_id,
    file_name,
    mime_type,
    size_bytes,
    storage_path,
    upload_state,
    attempt_count,
    position,
    created_at,
    updated_at
  ) values (
    attachment_id,
    new.user_id,
    new.id,
    left(
      coalesce(
        nullif(
          regexp_replace(
            regexp_replace(new.storage_path, '^.*/', ''),
            '[[:cntrl:]/\\]',
            '_',
            'g'
          ),
          ''
        ),
        'attachment'
      ),
      255
    ),
    case
      when new.mime_type is not null
        and char_length(new.mime_type) between 3 and 255
        and strpos(new.mime_type, '/') > 1
        and new.mime_type !~ '[[:cntrl:]]'
      then new.mime_type
      else 'application/octet-stream'
    end,
    case
      when new.size_bytes between 0 and 524288000 then new.size_bytes
      else null
    end,
    new.storage_path,
    'uploaded',
    1,
    0,
    new.created_at,
    new.updated_at
  )
  on conflict (storage_path) do nothing;

  return new;
end;
$$;

revoke all on function morit.capture_legacy_item_attachment()
from public, anon, authenticated;

drop trigger if exists items_capture_legacy_attachment on morit.items;
create trigger items_capture_legacy_attachment
after insert or update of storage_path, kind on morit.items
for each row
when (
  new.storage_path is not null
  and new.kind in ('photo', 'video', 'file')
)
execute function morit.capture_legacy_item_attachment();

alter table morit.attachments enable row level security;

drop policy if exists attachments_owner_all on morit.attachments;
create policy attachments_owner_all on morit.attachments
for all to authenticated
using (
  user_id = (select auth.uid())
  and (select morit.can_access())
)
with check (
  user_id = (select auth.uid())
  and (select morit.can_access())
);

grant select, insert, update, delete
on table morit.attachments to authenticated;
revoke all on table morit.attachments from anon;

-- Reassert the private bucket policies in case the production bucket predates
-- the repository baseline.
drop policy if exists morit_storage_select on storage.objects;
create policy morit_storage_select on storage.objects
for select to authenticated
using (
  bucket_id = 'morit-files'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and (select morit.can_access())
);

drop policy if exists morit_storage_insert on storage.objects;
create policy morit_storage_insert on storage.objects
for insert to authenticated
with check (
  bucket_id = 'morit-files'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and (select morit.can_access())
);

drop policy if exists morit_storage_update on storage.objects;
create policy morit_storage_update on storage.objects
for update to authenticated
using (
  bucket_id = 'morit-files'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and (select morit.can_access())
)
with check (
  bucket_id = 'morit-files'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and (select morit.can_access())
);

drop policy if exists morit_storage_delete on storage.objects;
create policy morit_storage_delete on storage.objects
for delete to authenticated
using (
  bucket_id = 'morit-files'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and (select morit.can_access())
);

-- A previous deployment exposed public.profiles to anon. Remove every
-- anonymous/public SELECT-capable policy regardless of its historical name,
-- revoke table privileges, and restore only the owner's authenticated policy.
do $$
declare
  exposed_policy record;
begin
  for exposed_policy in
    select policyname
    from pg_policies
    where schemaname = 'public'
      and tablename = 'profiles'
      and cmd in ('ALL', 'SELECT')
      and (
        'public'::name = any (roles)
        or 'anon'::name = any (roles)
      )
  loop
    execute format(
      'drop policy if exists %I on public.profiles',
      exposed_policy.policyname
    );
  end loop;
end;
$$;

alter table public.profiles enable row level security;
revoke all privileges on table public.profiles from public, anon;

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own
on public.profiles
for select
to authenticated
using ((select auth.uid()) = id);
