-- 0003_least_privilege_grants.sql
--
-- RLS policies alone are not the whole security boundary — PostgreSQL GRANTs are checked
-- first, before any RLS policy is even evaluated. A role with no GRANT on a table gets denied
-- outright; a role WITH a GRANT still has RLS applied on top. This migration makes sure the
-- `anon` role (unauthenticated requests using the publishable key) has no standing grants on
-- user-owned tables at all, and `authenticated` only has exactly the verbs it needs.
--
-- Safe to re-run.

-- Explicitly revoke everything from anon and the default PUBLIC pseudo-role first, so nothing
-- is left over from Supabase's default "expose everything in public" table creation behavior.
revoke all on public.books       from anon, public;
revoke all on public.quotes      from anon, public;
revoke all on public.vocab_words from anon, public;

-- authenticated users get exactly CRUD — no TRUNCATE, no REFERENCES/TRIGGER, nothing beyond
-- what the app's own upsert/select/delete calls need. RLS policies from 0001 still apply on
-- top of these grants and are what actually restricts which ROWS are visible/writable.
grant select, insert, update, delete on public.books       to authenticated;
grant select, insert, update, delete on public.quotes      to authenticated;
grant select, insert, update, delete on public.vocab_words to authenticated;

-- Sequences (if any of these tables use a serial/identity column anywhere) must also be
-- explicitly grantable — harmless no-op if the tables only use client-generated UUIDs.
do $$
declare
  seq record;
begin
  for seq in
    select sequence_name from information_schema.sequences
    where sequence_schema = 'public'
      and sequence_name in (
        select column_default from information_schema.columns
        where table_schema = 'public' and table_name in ('books', 'quotes', 'vocab_words')
      )
  loop
    execute format('grant usage, select on sequence public.%I to authenticated', seq.sequence_name);
  end loop;
end $$;

-- Defense in depth: make sure no future table created in `public` accidentally inherits a
-- permissive default grant to anon/public.
alter default privileges in schema public revoke all on tables from anon, public;

-- No RPC/database functions are defined by this app's schema today (verified: the only
-- privileged operation, account deletion, is implemented as a Supabase Edge Function that uses
-- the service_role key server-side — see supabase/functions and AuthManager.deleteAccount()).
-- If a database function/RPC is added later, it MUST be reviewed against this checklist before
-- being exposed to `authenticated`/`anon`:
--   * Does it run as SECURITY DEFINER? If so, does it re-check auth.uid() itself internally
--     rather than trusting an argument the caller controls?
--   * Is it granted to `anon` when it shouldn't be?
--   * Could it be used to read/write rows the caller doesn't own by passing a different id?
