# Morit Edge Functions

`morit-download` is intentionally disabled. Do not restore an arbitrary URL
proxy until it has all of the following controls:

- verified Supabase user identity and `verify_jwt = true`
- fixed-IP egress or DNS pinning across every redirect
- canonical IPv4/IPv6 private-range blocking
- connect, header, idle, and total timeouts
- per-user concurrency, request, and byte quotas
- an opaque one-time ticket so source URLs and bearer tokens never enter the
  Android DownloadManager database or Edge request URL logs
