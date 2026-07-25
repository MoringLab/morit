alter function morit.set_updated_at() set search_path = '';
revoke execute on function morit.set_updated_at() from public, anon, authenticated;
