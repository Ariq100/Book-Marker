-- 0002_book_association_and_cover_url.sql
--
-- Additive-only schema changes to support:
--   * associating a quote/vocab word with the specific book it came from (not just a free-text
--     book title), matching Quote.bookID / VocabWord.bookID in the Swift models
--   * optional page number and free-text note on quotes/words
--   * a direct cover image URL, for books added via providers other than Open Library
--     (Book.coverURLString in the Swift model)
--
-- Nothing here drops or renames an existing column, and no existing row loses data.

alter table public.books  add column if not exists cover_url text;

alter table public.quotes add column if not exists book_id     uuid;
alter table public.quotes add column if not exists page_number integer;
alter table public.quotes add column if not exists note        text;

alter table public.vocab_words add column if not exists book_id     uuid;
alter table public.vocab_words add column if not exists page_number integer;
alter table public.vocab_words add column if not exists note        text;

-- book_id references the owning user's own books row. ON DELETE SET NULL rather than CASCADE:
-- deleting a book should not silently delete the quotes/words the user saved from it.
do $$
begin
  begin
    alter table public.quotes
      add constraint quotes_book_id_fkey foreign key (book_id) references public.books (id) on delete set null;
  exception when duplicate_object then null;
  end;

  begin
    alter table public.vocab_words
      add constraint vocab_words_book_id_fkey foreign key (book_id) references public.books (id) on delete set null;
  exception when duplicate_object then null;
  end;
end $$;

-- Page numbers, if present, must be a sane positive value.
do $$
begin
  begin
    alter table public.quotes add constraint quotes_page_number_check check (page_number is null or page_number > 0);
  exception when duplicate_object then null;
  end;

  begin
    alter table public.vocab_words add constraint vocab_words_page_number_check check (page_number is null or page_number > 0);
  exception when duplicate_object then null;
  end;
end $$;

-- Cap free-text note length defensively (input validation at the database layer too, not just
-- the client — see section 14 of the architecture notes / SECURITY.md).
do $$
begin
  begin
    alter table public.quotes add constraint quotes_note_length_check check (note is null or char_length(note) <= 2000);
  exception when duplicate_object then null;
  end;

  begin
    alter table public.vocab_words add constraint vocab_words_note_length_check check (note is null or char_length(note) <= 2000);
  exception when duplicate_object then null;
  end;
end $$;

create index if not exists quotes_book_id_idx      on public.quotes (book_id);
create index if not exists vocab_words_book_id_idx  on public.vocab_words (book_id);

-- Note: book_id is NOT covered by a separate RLS policy — it doesn't need to be. The existing
-- `auth.uid() = user_id` policies from migration 0001 already restrict every row (and therefore
-- every book_id a user could reference) to their own data; a user cannot set book_id to point at
-- another user's book because they can't SELECT that book's id in the first place to construct
-- such a request, and even if they guessed a UUID, the FK would still resolve to a row RLS
-- prevents everyone else from reading — it simply wouldn't be a usable association client-side.
