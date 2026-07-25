-- These legacy post-attachment policies were missing a bucket predicate in
-- USING. Because Storage policies are permissive, they could otherwise bypass
-- stricter DELETE/UPDATE policies on any bucket that reused a user-id prefix.

alter policy "Allow user to delete their own files"
on storage.objects
using (
  bucket_id = 'post-attachments'
  and auth.uid() = ((storage.foldername(name))[1])::uuid
);

alter policy "Allow user to update their own files"
on storage.objects
using (
  bucket_id = 'post-attachments'
  and auth.uid() = ((storage.foldername(name))[1])::uuid
)
with check (
  bucket_id = 'post-attachments'
);
