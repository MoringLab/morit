-- Today tasks remain memo rows; scheduled notifications use reminder rows.
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
      and item.kind in ('memo', 'reminder')
  ) then
    raise exception 'attachments require an owned memo or reminder item'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function morit.enforce_attachment_memo()
from public, anon, authenticated;
