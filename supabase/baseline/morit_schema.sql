-- Snapshot of the Morit-owned backend as of 2026-07-23.
-- This is a reproducible baseline for a fresh Supabase project. The production
-- project predates this repository, so do not re-apply this file there.

create schema morit;
grant usage on schema morit to authenticated, service_role;

create table morit.folders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  parent_id uuid references morit.folders(id) on delete cascade,
  name text not null check (
    char_length(trim(name)) between 1 and 80
  ),
  color bigint not null default 4280191205,
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table morit.items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  folder_id uuid references morit.folders(id) on delete set null,
  kind text not null check (
    kind in ('memo', 'link', 'bookmark', 'photo', 'video', 'file', 'reminder')
  ),
  title text not null default '',
  note text not null default '',
  source_url text,
  storage_path text,
  mime_type text,
  size_bytes bigint check (size_bytes is null or size_bytes >= 0),
  metadata jsonb not null default '{}'::jsonb,
  is_favorite boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table morit.downloads (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  item_id uuid references morit.items(id) on delete set null,
  source_url text not null,
  mode text not null default 'auto' check (mode in ('auto', 'direct', 'proxy')),
  quality text not null default 'original',
  state text not null default 'queued' check (
    state in ('queued', 'running', 'paused', 'completed', 'failed', 'canceled')
  ),
  progress integer not null default 0 check (progress between 0 and 100),
  native_id bigint,
  local_path text,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  title text not null default '다운로드'
);

create table morit.preferences (
  user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  download_mode text not null default 'auto' check (
    download_mode in ('auto', 'direct', 'proxy')
  ),
  notifications_enabled boolean not null default true,
  auto_sync boolean not null default true,
  settings jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table morit.reminders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  item_id uuid not null references morit.items(id) on delete cascade,
  scheduled_at timestamptz not null,
  fired_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, item_id)
);

create index folders_parent_fk_idx on morit.folders(parent_id);
create index folders_user_parent_idx on morit.folders(user_id, parent_id, position);
create index folders_user_updated_idx on morit.folders(user_id, updated_at desc);
create index items_folder_fk_idx on morit.items(folder_id);
create index items_user_folder_idx on morit.items(user_id, folder_id, updated_at desc);
create index items_user_kind_idx on morit.items(user_id, kind, updated_at desc);
create index items_user_updated_idx on morit.items(user_id, updated_at desc);
create index downloads_item_fk_idx on morit.downloads(item_id);
create index downloads_user_updated_idx on morit.downloads(user_id, updated_at desc);
create index reminders_item_fk_idx on morit.reminders(item_id);
create index reminders_user_scheduled_idx on morit.reminders(user_id, scheduled_at);

create function morit.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger folders_set_updated_at before update on morit.folders
for each row execute function morit.set_updated_at();
create trigger items_set_updated_at before update on morit.items
for each row execute function morit.set_updated_at();
create trigger downloads_set_updated_at before update on morit.downloads
for each row execute function morit.set_updated_at();
create trigger preferences_set_updated_at before update on morit.preferences
for each row execute function morit.set_updated_at();
create trigger reminders_set_updated_at before update on morit.reminders
for each row execute function morit.set_updated_at();

alter table morit.folders enable row level security;
alter table morit.items enable row level security;
alter table morit.downloads enable row level security;
alter table morit.preferences enable row level security;
alter table morit.reminders enable row level security;

create policy folders_owner_all on morit.folders
for all to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));
create policy items_owner_all on morit.items
for all to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));
create policy downloads_owner_all on morit.downloads
for all to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));
create policy preferences_owner_all on morit.preferences
for all to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));
create policy reminders_owner_all on morit.reminders
for all to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

grant select, insert, update, delete on all tables in schema morit to authenticated;
revoke all on all tables in schema morit from anon;

insert into storage.buckets (id, name, public, file_size_limit)
values ('morit-files', 'morit-files', false, 524288000);

create policy morit_storage_select on storage.objects
for select to authenticated
using (
  bucket_id = 'morit-files'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);
create policy morit_storage_insert on storage.objects
for insert to authenticated
with check (
  bucket_id = 'morit-files'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);
create policy morit_storage_update on storage.objects
for update to authenticated
using (
  bucket_id = 'morit-files'
  and (storage.foldername(name))[1] = (select auth.uid())::text
)
with check (
  bucket_id = 'morit-files'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);
create policy morit_storage_delete on storage.objects
for delete to authenticated
using (
  bucket_id = 'morit-files'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);
