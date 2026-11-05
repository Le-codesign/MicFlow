-- MicFlow 2.9: Universal Clipboard. Items are end-to-end encrypted on the device and only kept
-- while being delivered (the apps delete anything older than a few minutes).
create table if not exists public.clipboard_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  device text not null,
  device_name text,
  kind text not null check (kind in ('text', 'image')),
  data text not null check (length(data) <= 7500000),
  created_at timestamptz not null default now()
);
create index if not exists clipboard_items_user_time on public.clipboard_items (user_id, created_at);
alter table public.clipboard_items enable row level security;
drop policy if exists "own clipboard" on public.clipboard_items;
create policy "own clipboard" on public.clipboard_items for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
alter publication supabase_realtime add table public.clipboard_items;
