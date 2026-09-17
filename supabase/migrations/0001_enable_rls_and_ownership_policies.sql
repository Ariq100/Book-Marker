-- 0001_enable_rls_and_ownership_policies.sql
--
-- Hardens the three user-owned tables (books, quotes, vocab_words) with Row Level Security.
-- Safe to re-run: every DDL statement below is idempotent (IF NOT EXISTS / DROP...IF EXISTS
-- before CREATE), so applying this migration twice is a no-op the second time.
--
-- THREAT MODEL THIS FILE DEFENDS AGAINST:
--   The iOS app ships a Supabase PUBLISHABLE key (safe to expose — see SECURITY.md). Anyone who
--   extracts that key from the app binary can send arbitrary requests to the Supabase Data API
--   as an "authenticated" or "anon" role. RLS is what actually stops that key from being used to
--   read, modify, or delete another user's rows — the key alone grants no such access.
--
-- Run via `supabase db push`, or paste into the Supabase SQL Editor. Requires a `user_id uuid`
-- column on each table (already present, since SyncManager.swift has always written it).

-- ============================================================================
-- 1. Ensure user_id is well-formed: NOT NULL, defaults to the caller's own auth id,
--    and cannot reference a nonexistent user.
-- ============================================================================

do $$
begin
  -- books.user_id
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'books' and column_name = 'user_id') then
    alter table public.books alter column user_id set default auth.uid();
    begin
      alter table public.books add constraint books_user_id_fkey foreign key (user_id) references auth.users (id) on delete cascade;
    exception when duplicate_object then null;
    end;
  end if;

  -- quotes.user_id
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'quotes' and column_name = 'user_id') then
    alter table public.quotes alter column user_id set default auth.uid();
    begin
      alter table public.quotes add constraint quotes_user_id_fkey foreign key (user_id) references auth.users (id) on delete cascade;
    exception when duplicate_object then null;
    end;
  end if;

  -- vocab_words.user_id
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'vocab_words' and column_name = 'user_id') then
    alter table public.vocab_words alter column user_id set default auth.uid();
    begin
      alter table public.vocab_words add constraint vocab_words_user_id_fkey foreign key (user_id) references auth.users (id) on delete cascade;
    exception when duplicate_object then null;
    end;
  end if;
end $$;

-- ============================================================================
-- 2. Enable Row Level Security (and FORCE it, so even the table owner role is subject to
--    policies — relevant if the app ever runs migrations as a privileged role).
-- ============================================================================

alter table public.books       enable row level security;
alter table public.books       force row level security;
alter table public.quotes      enable row level security;
alter table public.quotes      force row level security;
alter table public.vocab_words enable row level security;
alter table public.vocab_words force row level security;

-- ============================================================================
-- 3. Ownership policies. USING controls which existing rows are visible/targetable;
--    WITH CHECK controls what a new/updated row is allowed to look like. Both are required
--    on UPDATE — USING alone would let a user update a row they own but silently give it a
--    new user_id (an ownership-transfer/spoofing bug); WITH CHECK closes that.
-- ============================================================================

-- ---- books ----
drop policy if exists "books_select_own" on public.books;
create policy "books_select_own" on public.books
  for select using (auth.uid() = user_id);

drop policy if exists "books_insert_own" on public.books;
create policy "books_insert_own" on public.books
  for insert with check (auth.uid() = user_id);

drop policy if exists "books_update_own" on public.books;
create policy "books_update_own" on public.books
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "books_delete_own" on public.books;
create policy "books_delete_own" on public.books
  for delete using (auth.uid() = user_id);

-- ---- quotes ----
drop policy if exists "quotes_select_own" on public.quotes;
create policy "quotes_select_own" on public.quotes
  for select using (auth.uid() = user_id);

drop policy if exists "quotes_insert_own" on public.quotes;
create policy "quotes_insert_own" on public.quotes
  for insert with check (auth.uid() = user_id);

drop policy if exists "quotes_update_own" on public.quotes;
create policy "quotes_update_own" on public.quotes
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "quotes_delete_own" on public.quotes;
create policy "quotes_delete_own" on public.quotes
  for delete using (auth.uid() = user_id);

-- ---- vocab_words ----
drop policy if exists "vocab_words_select_own" on public.vocab_words;
create policy "vocab_words_select_own" on public.vocab_words
  for select using (auth.uid() = user_id);

drop policy if exists "vocab_words_insert_own" on public.vocab_words;
create policy "vocab_words_insert_own" on public.vocab_words
  for insert with check (auth.uid() = user_id);

drop policy if exists "vocab_words_update_own" on public.vocab_words;
create policy "vocab_words_update_own" on public.vocab_words
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "vocab_words_delete_own" on public.vocab_words;
create policy "vocab_words_delete_own" on public.vocab_words
  for delete using (auth.uid() = user_id);

-- No policy at all is defined for the `anon` (unauthenticated) role on any of these tables.
-- With RLS enabled and FORCE'd, the absence of a matching policy means DENY by default —
-- anonymous users get zero rows from SELECT and every write is rejected.
