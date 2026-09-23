-- account_deletion_tests.sql
--
-- Verifies that deleting a user from auth.users removes EVERY row of personal data stored for
-- them, and nothing belonging to anyone else. This is the database-level guarantee behind the
-- privacy policy's "deleting your account deletes all of its data" promise: even if the
-- delete-account Edge Function's explicit per-table deletes were skipped, the ON DELETE CASCADE
-- foreign keys (migrations 0001 and 0004) must still leave no orphans.
--
-- HOW TO RUN (disposable/staging database only — same as rls_tests.sql):
--   psql "$SUPABASE_DB_URL" -f supabase/tests/account_deletion_tests.sql
--
-- Every assertion RAISEs on failure, so "the script ran to completion" IS the pass signal.
-- Everything runs inside a transaction that is rolled back at the end.
--
-- If you add a new table that stores per-user data, add it to the checks below (and to
-- USER_TABLES in supabase/functions/delete-account/index.ts).

begin;

do $$
declare
  doomed uuid := '00000000-0000-0000-0000-0000000000dd';
  keeper uuid := '00000000-0000-0000-0000-0000000000ee';
  doomed_book uuid := gen_random_uuid();
  remaining int;
begin
  insert into auth.users (id, email) values
    (doomed, 'delete-test-doomed@example.invalid'),
    (keeper, 'delete-test-keeper@example.invalid');

  -- One row in every user-owned table for each user.
  insert into public.books (id, user_id, local_id, title, author) values
    (doomed_book, doomed, gen_random_uuid(), 'Doomed Book', 'Author'),
    (gen_random_uuid(), keeper, gen_random_uuid(), 'Keeper Book', 'Author');
  insert into public.quotes (id, user_id, local_id, text, book_id) values
    (gen_random_uuid(), doomed, gen_random_uuid(), 'Doomed quote', doomed_book),
    (gen_random_uuid(), keeper, gen_random_uuid(), 'Keeper quote', null);
  insert into public.vocab_words (id, user_id, local_id, word, book_id) values
    (gen_random_uuid(), doomed, gen_random_uuid(), 'doomed', doomed_book),
    (gen_random_uuid(), keeper, gen_random_uuid(), 'keeper', null);
  insert into public.quote_extractions (user_id) values (doomed), (keeper);

  -- What the delete-account Edge Function ultimately does.
  delete from auth.users where id = doomed;

  select (select count(*) from public.books             where user_id = doomed)
       + (select count(*) from public.quotes            where user_id = doomed)
       + (select count(*) from public.vocab_words       where user_id = doomed)
       + (select count(*) from public.quote_extractions where user_id = doomed)
       + (select count(*) from auth.identities          where user_id = doomed)
    into remaining;
  if remaining <> 0 then
    raise exception 'FAIL: % row(s) of the deleted user''s data survived account deletion', remaining;
  end if;
  raise notice 'PASS: deleting the auth user removed all of their books, quotes, words and usage rows';

  select (select count(*) from public.books             where user_id = keeper)
       + (select count(*) from public.quotes            where user_id = keeper)
       + (select count(*) from public.vocab_words       where user_id = keeper)
       + (select count(*) from public.quote_extractions where user_id = keeper)
    into remaining;
  if remaining <> 4 then
    raise exception 'FAIL: deleting one user removed another user''s data (% of 4 rows left)', remaining;
  end if;
  raise notice 'PASS: other users'' data is untouched';
end $$;

rollback;
