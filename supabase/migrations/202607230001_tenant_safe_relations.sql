-- Keep every Morit relationship inside the owning auth user.
-- The redundant (user_id, id) keys exist so child tables can use composite FKs.

alter table morit.folders
  add constraint folders_user_id_id_key unique (user_id, id);

alter table morit.items
  add constraint items_user_id_id_key unique (user_id, id);

alter table morit.folders
  drop constraint folders_parent_id_fkey,
  add constraint folders_parent_owner_fkey
    foreign key (user_id, parent_id)
    references morit.folders (user_id, id)
    on delete cascade;

alter table morit.items
  drop constraint items_folder_id_fkey,
  add constraint items_folder_owner_fkey
    foreign key (user_id, folder_id)
    references morit.folders (user_id, id)
    on delete set null (folder_id);

alter table morit.downloads
  drop constraint downloads_item_id_fkey,
  add constraint downloads_item_owner_fkey
    foreign key (user_id, item_id)
    references morit.items (user_id, id)
    on delete set null (item_id);

alter table morit.reminders
  drop constraint reminders_item_id_fkey,
  add constraint reminders_item_owner_fkey
    foreign key (user_id, item_id)
    references morit.items (user_id, id)
    on delete cascade;
