-- MicFlow 2.6: every setting (shortcuts, remaps, mouse, sound, voice options) saved with the account.
-- Run once in Supabase › SQL Editor. The API key column keeps only sealed copies (see KeyVault).
alter table public.profiles add column if not exists settings jsonb;
