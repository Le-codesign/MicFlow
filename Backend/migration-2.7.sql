-- MicFlow 2.7: each feature request says which platform it's for (Mac, Android, Windows).
-- Requests posted before this were all made in the Mac app.
alter table public.feature_requests add column if not exists platform text not null default 'mac';
alter table public.feature_requests drop constraint if exists feature_requests_platform_check;
alter table public.feature_requests add constraint feature_requests_platform_check check (platform in ('mac', 'android', 'windows'));
drop view if exists public.feature_request_list;
create view public.feature_request_list as
  select r.id, r.author_id, r.title, r.body, r.images, r.author_name, r.author_avatar, r.created_at, r.platform,
         coalesce(sum(case when v.value = 1 then 1 else 0 end), 0)::int as upvotes,
         coalesce(sum(case when v.value = -1 then 1 else 0 end), 0)::int as downvotes,
         (select count(*) from public.comments c where c.request_id = r.id)::int as comments,
         coalesce(sum(v.value), 0)::int as score
  from public.feature_requests r
  left join public.votes v on v.request_id = r.id
  group by r.id;
grant select on public.feature_request_list to anon, authenticated;
