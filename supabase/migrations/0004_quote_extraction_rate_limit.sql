-- 0004_quote_extraction_rate_limit.sql
--
-- Usage ledger for the `extract-quote` Edge Function. Every Gemini call costs money and is paid
-- by the project, not the user, so a signed-in user (or anyone who scripts the publishable key
-- plus a throwaway account) must not be able to call it without limit. The function records one
-- row per call and refuses new calls once a user exceeds the hourly/daily caps.
--
-- Only the Edge Function touches this table, using the service-role client. `authenticated`
-- and `anon` get no grants at all, so a user can neither read their counters nor delete rows
-- to reset them.
--
-- Safe to re-run.

create table if not exists public.quote_extractions (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

create index if not exists quote_extractions_user_created_idx
  on public.quote_extractions (user_id, created_at desc);

alter table public.quote_extractions enable row level security;
alter table public.quote_extractions force row level security;

revoke all on public.quote_extractions from anon, authenticated, public;
-- No policies: with RLS forced and no grants, only the service role (which bypasses RLS) can
-- read or write this table.
