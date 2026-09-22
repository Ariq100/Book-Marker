-- 0005_text_length_limits.sql
--
-- Caps the size of every free-text column users can write. The app already limits what it sends,
-- but anyone holding the publishable key and an account can call the Data API directly — without
-- a database-level cap they could store arbitrarily large rows at the project's expense.
--
-- Limits are generous relative to real use (the app caps quotes at 2,000 characters).
-- Constraints are added NOT VALID: they are enforced on every new INSERT/UPDATE immediately, but
-- existing rows are not re-checked, so this migration cannot fail on legacy data.
--
-- Safe to re-run.

do $$
begin
  begin alter table public.books add constraint books_title_length_check check (char_length(title) <= 500) not valid;
  exception when duplicate_object then null; end;
  begin alter table public.books add constraint books_author_length_check check (char_length(author) <= 500) not valid;
  exception when duplicate_object then null; end;
  begin alter table public.books add constraint books_olid_length_check check (olid is null or char_length(olid) <= 200) not valid;
  exception when duplicate_object then null; end;
  begin alter table public.books add constraint books_cover_url_check
    check (cover_url is null or char_length(cover_url) <= 2000) not valid;
  exception when duplicate_object then null; end;

  begin alter table public.quotes add constraint quotes_text_length_check check (char_length(text) <= 5000) not valid;
  exception when duplicate_object then null; end;
  begin alter table public.quotes add constraint quotes_book_title_length_check check (char_length(book_title) <= 500) not valid;
  exception when duplicate_object then null; end;

  begin alter table public.vocab_words add constraint vocab_words_word_length_check check (char_length(word) <= 200) not valid;
  exception when duplicate_object then null; end;
  begin alter table public.vocab_words add constraint vocab_words_definition_length_check check (char_length(definition) <= 5000) not valid;
  exception when duplicate_object then null; end;
end $$;
