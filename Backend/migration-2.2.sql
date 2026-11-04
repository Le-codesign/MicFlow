-- MicFlow 2.2: delete buttons. The list now says who posted each request, and people can delete
-- their own pictures (admins anyone's). Running it again is safe.
drop view if exists public.feature_request_list;
create view public.feature_request_list as
  select r.id, r.author_id, r.title, r.body, r.images, r.author_name, r.author_avatar, r.created_at,
         coalesce(sum(case when v.value = 1 then 1 else 0 end), 0)::int as upvotes,
         coalesce(sum(case when v.value = -1 then 1 else 0 end), 0)::int as downvotes,
         (select count(*) from public.comments c where c.request_id = r.id)::int as comments,
         coalesce(sum(v.value), 0)::int as score
  from public.feature_requests r
  left join public.votes v on v.request_id = r.id
  group by r.id;
grant select on public.feature_request_list to anon, authenticated;

drop policy if exists "delete feature images" on storage.objects;
create policy "delete feature images" on storage.objects for delete
  using (bucket_id = 'feature-images'
         and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
