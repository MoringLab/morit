-- Serialize tree edits per owner and reject a parent that is already below the
-- edited folder. Existing malformed rows are preserved; every future insert or
-- parent change is checked.

alter table morit.folders
  drop constraint if exists folders_parent_not_self;

alter table morit.folders
  add constraint folders_parent_not_self
  check (parent_id is null or parent_id <> id)
  not valid;

create or replace function morit.prevent_folder_cycle()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'morit.folder.tree:' || new.user_id::text,
      0
    )
  );

  if new.parent_id is null then
    return new;
  end if;

  if new.parent_id = new.id then
    raise exception 'a folder cannot contain itself'
      using errcode = '23514';
  end if;

  if exists (
    with recursive ancestors(id, parent_id) as (
      select folder.id, folder.parent_id
      from morit.folders as folder
      where folder.user_id = new.user_id
        and folder.id = new.parent_id

      union

      select parent.id, parent.parent_id
      from ancestors
      join morit.folders as parent
        on parent.user_id = new.user_id
       and parent.id = ancestors.parent_id
    )
    select 1
    from ancestors
    where id = new.id
  ) then
    raise exception 'a folder cannot be moved below its descendant'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function morit.prevent_folder_cycle()
from public, anon, authenticated;

drop trigger if exists folders_prevent_cycle on morit.folders;
create trigger folders_prevent_cycle
before insert or update of id, user_id, parent_id on morit.folders
for each row execute function morit.prevent_folder_cycle();
