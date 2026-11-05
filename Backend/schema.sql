-- MicFlow's database on Supabase. Paste all of this into Supabase › SQL Editor › New query, and Run.
-- Running it again is safe.

-- Admins: put your own Google account's email here (see SETUP.md). Admins can delete any request
-- or comment.
create table if not exists public.admins (email text primary key);
alter table public.admins enable row level security;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where email = auth.jwt() ->> 'email');
$$;

-- True for a real (Google) account, false for the invisible device account used for voting.
create or replace function public.is_real_user() returns boolean
language sql stable as $$
  select auth.uid() is not null and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false;
$$;

-- Preferences and API key: only the owner can read or change their row.
create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  email text,
  name text,
  instructions text not null default '',
  instructions_enabled boolean not null default true,
  my_words jsonb not null default '[]',
  mix_ups jsonb not null default '[]',
  api_key text,
  settings jsonb,
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists "own profile" on public.profiles;
create policy "own profile" on public.profiles for all
  using (auth.uid() = id) with check (auth.uid() = id and public.is_real_user());

-- Feature requests: anyone reads; signed-in people post; authors and admins delete.
create table if not exists public.feature_requests (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null default auth.uid() references auth.users on delete cascade,
  author_name text,
  author_avatar text,
  title text not null check (char_length(title) between 4 and 140),
  body text not null default '' check (char_length(body) <= 5000),
  images text[] not null default '{}' check (cardinality(images) <= 6),
  created_at timestamptz not null default now()
);
alter table public.feature_requests enable row level security;
drop policy if exists "read requests" on public.feature_requests;
create policy "read requests" on public.feature_requests for select using (true);
drop policy if exists "post requests" on public.feature_requests;
create policy "post requests" on public.feature_requests for insert
  with check (public.is_real_user() and author_id = auth.uid());
drop policy if exists "delete requests" on public.feature_requests;
create policy "delete requests" on public.feature_requests for delete
  using (author_id = auth.uid() or public.is_admin());

create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.feature_requests on delete cascade,
  author_id uuid not null default auth.uid() references auth.users on delete cascade,
  author_name text,
  author_avatar text,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
alter table public.comments enable row level security;
drop policy if exists "read comments" on public.comments;
create policy "read comments" on public.comments for select using (true);
drop policy if exists "post comments" on public.comments;
create policy "post comments" on public.comments for insert
  with check (public.is_real_user() and author_id = auth.uid());
drop policy if exists "delete comments" on public.comments;
create policy "delete comments" on public.comments for delete
  using (author_id = auth.uid() or public.is_admin());

-- Votes: one per person (or device) per request; anyone, including the device account, can vote.
create table if not exists public.votes (
  request_id uuid not null references public.feature_requests on delete cascade,
  voter_id uuid not null default auth.uid() references auth.users on delete cascade,
  value smallint not null check (value in (-1, 1)),
  primary key (request_id, voter_id)
);
alter table public.votes enable row level security;
drop policy if exists "own votes" on public.votes;
create policy "own votes" on public.votes for all
  using (voter_id = auth.uid()) with check (voter_id = auth.uid());

-- The list the app shows: each request with its vote and comment counts.
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

-- Pictures for requests: public to view by link; each person uploads only into their own folder.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('feature-images', 'feature-images', true, 5242880, array['image/jpeg', 'image/png'])
on conflict (id) do nothing;
drop policy if exists "upload own feature images" on storage.objects;
create policy "upload own feature images" on storage.objects for insert
  with check (bucket_id = 'feature-images' and public.is_real_user()
              and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "delete feature images" on storage.objects;
create policy "delete feature images" on storage.objects for delete
  using (bucket_id = 'feature-images'
         and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
