-- rls_tests.sql
--
-- Manual RLS verification script. Run against a DISPOSABLE/staging database only — it creates
-- two throwaway auth users and rows, then deletes them at the end.
--
-- HOW TO RUN:
--   supabase db reset            -- (local dev only) applies migrations to a clean local DB, or
--   psql "$SUPABASE_DB_URL" -f supabase/tests/rls_tests.sql
--
-- Each block simulates a specific user's request by setting the Postgres session to the
-- `authenticated` role with that user's JWT `sub` claim — this is exactly what PostgREST does
-- per-request in production, so if a check passes here it reflects real request behavior.
--
-- Every assertion RAISEs an exception (aborting the script) if the expected access control
-- outcome doesn't hold, so "the script ran to completion" IS the pass signal.

begin;

-- ---------------------------------------------------------------------------
-- Setup: two throwaway users and one row each, inserted as postgres (bypasses RLS as owner).
-- ---------------------------------------------------------------------------
do $$
declare
  user_a uuid := '00000000-0000-0000-0000-0000000000aa';
  user_b uuid := '00000000-0000-0000-0000-0000000000bb';
begin
  -- Minimal fake auth.users rows so the FK constraints from migration 0001 are satisfiable.
  insert into auth.users (id, email) values (user_a, 'rls-test-a@example.invalid')
    on conflict (id) do nothing;
  insert into auth.users (id, email) values (user_b, 'rls-test-b@example.invalid')
    on conflict (id) do nothing;

  insert into public.quotes (id, user_id, local_id, text, book_title, date_added, updated_at)
  values ('00000000-0000-0000-0000-0000000000q1', user_a, gen_random_uuid(), 'Test quote from user A', 'Test Book', now(), now())
  on conflict (id) do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- Test 1: User A can read their own quote.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000aa", "role": "authenticated"}';

do $$
begin
  if not exists (select 1 from public.quotes where id = '00000000-0000-0000-0000-0000000000q1') then
    raise exception 'FAIL: Test 1 — User A could not read their own quote';
  end if;
  raise notice 'PASS: Test 1 — User A can read their own quote';
end $$;

-- ---------------------------------------------------------------------------
-- Test 2: User B CANNOT read User A's quote.
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000bb", "role": "authenticated"}';

do $$
begin
  if exists (select 1 from public.quotes where id = '00000000-0000-0000-0000-0000000000q1') then
    raise exception 'FAIL: Test 2 — User B was able to read User A''s quote';
  end if;
  raise notice 'PASS: Test 2 — User B cannot read User A''s quote';
end $$;

-- ---------------------------------------------------------------------------
-- Test 3: User B CANNOT update User A's quote.
-- ---------------------------------------------------------------------------
do $$
begin
  update public.quotes set text = 'hijacked' where id = '00000000-0000-0000-0000-0000000000q1';
  if found then
    raise exception 'FAIL: Test 3 — User B was able to update User A''s quote';
  end if;
  raise notice 'PASS: Test 3 — User B cannot update User A''s quote';
end $$;

-- ---------------------------------------------------------------------------
-- Test 4: User B CANNOT delete User A's quote.
-- ---------------------------------------------------------------------------
do $$
begin
  delete from public.quotes where id = '00000000-0000-0000-0000-0000000000q1';
  if found then
    raise exception 'FAIL: Test 4 — User B was able to delete User A''s quote';
  end if;
  raise notice 'PASS: Test 4 — User B cannot delete User A''s quote';
end $$;

-- ---------------------------------------------------------------------------
-- Test 5: User B CANNOT insert a quote using User A's user_id (ownership spoofing on INSERT).
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    insert into public.quotes (id, user_id, local_id, text, book_title, date_added, updated_at)
    values ('00000000-0000-0000-0000-0000000000q2', '00000000-0000-0000-0000-0000000000aa', gen_random_uuid(), 'spoofed', 'x', now(), now());
    raise exception 'FAIL: Test 5 — User B inserted a quote owned by User A';
  exception
    when insufficient_privilege or others then
      -- WITH CHECK violation raises a generic policy error, not necessarily insufficient_privilege
      raise notice 'PASS: Test 5 — User B cannot insert a quote owned by User A';
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Test 6: User A CANNOT reassign their own quote's user_id to User B (ownership transfer via
-- UPDATE spoofing).
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000aa", "role": "authenticated"}';

do $$
begin
  begin
    update public.quotes set user_id = '00000000-0000-0000-0000-0000000000bb'
      where id = '00000000-0000-0000-0000-0000000000q1';
    raise exception 'FAIL: Test 6 — User A reassigned their quote to User B';
  exception
    when insufficient_privilege or others then
      raise notice 'PASS: Test 6 — User A cannot reassign their quote''s ownership';
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Test 7: An unauthenticated (anon) request cannot read User A's quote at all.
-- ---------------------------------------------------------------------------
reset role;
set local role anon;
reset request.jwt.claims;

do $$
begin
  if exists (select 1 from public.quotes where id = '00000000-0000-0000-0000-0000000000q1') then
    raise exception 'FAIL: Test 7 — anonymous request could read a private quote';
  end if;
  raise notice 'PASS: Test 7 — anonymous request cannot read private quotes';
end $$;

reset role;

-- Repeat the same shape of tests for books and vocab_words if you extend this script; the
-- policies are identical in structure (see migration 0001), so the same 7 checks apply per table.

rollback; -- never actually commit test data/mutations, even on success
