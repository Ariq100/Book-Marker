-- 0006_keepalive_rpc.sql
--
-- A trivial RPC that the scheduled keep-alive job (scripts/supabase_keepalive.sh, run by
-- .github/workflows/supabase-keepalive.yml) calls every few days. Supabase pauses free-tier
-- projects after 7 days without activity, and a paused project makes every sign-in, sync and
-- Edge Function call in the app fail until someone restores it by hand in the dashboard.
--
-- The job authenticates with only the PUBLISHABLE key, so this function is granted to `anon`.
-- It passes the RPC checklist at the end of migration 0003:
--   * SECURITY INVOKER (not definer) — it runs with the caller's own, minimal privileges.
--   * It takes no arguments and reads no table; it returns the server clock and nothing else.
--   * It can't touch any user's rows, whoever calls it.
--
-- Safe to re-run.

create or replace function public.keepalive()
returns timestamptz
language sql
stable
security invoker
set search_path = ''
as $$
  select now();
$$;

comment on function public.keepalive() is
  'Called by the scheduled keep-alive job so the Supabase project is never paused for inactivity.';

-- Functions are executable by PUBLIC by default; grant exactly the roles that need it.
revoke all on function public.keepalive() from public;
grant execute on function public.keepalive() to anon, authenticated;
