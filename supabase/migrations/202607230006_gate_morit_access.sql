-- Do not treat any authenticated JWT as a completed Morit login. Access is
-- granted only after verified email/profile onboarding and, when the account
-- has a verified MFA factor, an AAL2 challenge.

create or replace function morit.can_access()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from auth.users as u
    join public.profiles as p on p.id = u.id
    where u.id = auth.uid()
      and u.email_confirmed_at is not null
      and char_length(btrim(p.full_name)) between 2 and 100
      and char_length(p.username) between 3 and 30
      and p.username ~ '^[A-Za-z0-9._가-힣]+$'
      and p.username !~ '^\.'
      and p.username !~ '\.$'
      and strpos(p.username, '..') = 0
      and p.birth_date is not null
      and p.birth_date <= current_date
      and (
        not exists (
          select 1
          from auth.mfa_factors as f
          where f.user_id = u.id
            and f.status::text = 'verified'
        )
        or coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
      )
  );
$$;

revoke all on function morit.can_access() from public, anon;
grant execute on function morit.can_access() to authenticated;

drop policy if exists folders_owner_all on morit.folders;
create policy folders_owner_all on morit.folders
for all to authenticated
using (user_id = (select auth.uid()) and (select morit.can_access()))
with check (user_id = (select auth.uid()) and (select morit.can_access()));

drop policy if exists items_owner_all on morit.items;
create policy items_owner_all on morit.items
for all to authenticated
using (user_id = (select auth.uid()) and (select morit.can_access()))
with check (user_id = (select auth.uid()) and (select morit.can_access()));

drop policy if exists downloads_owner_all on morit.downloads;
create policy downloads_owner_all on morit.downloads
for all to authenticated
using (user_id = (select auth.uid()) and (select morit.can_access()))
with check (user_id = (select auth.uid()) and (select morit.can_access()));

drop policy if exists reminders_owner_all on morit.reminders;
create policy reminders_owner_all on morit.reminders
for all to authenticated
using (user_id = (select auth.uid()) and (select morit.can_access()))
with check (user_id = (select auth.uid()) and (select morit.can_access()));

drop policy if exists preferences_owner_all on morit.preferences;
create policy preferences_owner_all on morit.preferences
for all to authenticated
using (user_id = (select auth.uid()) and (select morit.can_access()))
with check (user_id = (select auth.uid()) and (select morit.can_access()));

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
