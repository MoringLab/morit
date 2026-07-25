-- RLS policies need this helper, but anonymous clients must not use it as a
-- public permission-level lookup RPC.
revoke all on function public.get_permission_level(uuid) from public, anon;
grant execute on function public.get_permission_level(uuid) to authenticated;
