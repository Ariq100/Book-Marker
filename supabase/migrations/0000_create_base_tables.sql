-- 0000_create_base_tables.sql
--
-- Creates the three user-owned tables the rest of the migrations assume already exist.
-- Migrations 0001 (RLS), 0002 (additive columns) and 0003 (grants) all *harden* or *extend*
-- these tables; none of them creates one. Without this file `supabase db push` fails on
-- 0001's `alter table public.books enable row level security`.
--
-- Column names and types mirror the Codable DTOs in Book Marker/Services/SyncManager.swift
-- (RemoteBook / RemoteQuote / RemoteVocabWord) — those CodingKeys are the contract.
--
-- Deliberately NOT included here (migration 0002 adds them, so it stays meaningful):
--   books.cover_url, quotes/vocab_words.book_id, .page_number, .note
--
-- Safe to re-run: every statement is IF NOT EXISTS.

create table if not exists public.books (
  id         uuid primary key,
  user_id    uuid not null,
  local_id   uuid not null,
  title      text not null,
  author     text not null,
  cover_id   integer,
  olid       text,
  shelf      text not null default 'Bucket List',
  date_added timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.quotes (
  id         uuid primary key,
  user_id    uuid not null,
  local_id   uuid not null,
  text       text not null,
  book_title text not null default '',
  date_added timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.vocab_words (
  id         uuid primary key,
  user_id    uuid not null,
  local_id   uuid not null,
  word       text not null,
  definition text not null default '',
  date_added timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- `shelf` is persisted as Shelf.rawValue from the Swift enum; keep the DB in sync with it so a
-- malformed client can't write a value the app can't decode back (Shelf(rawValue:) would nil out).
do $$
begin
  begin
    alter table public.books
      add constraint books_shelf_check check (shelf in ('Reading', 'Bucket List', 'Done'));
  exception when duplicate_object then null;
  end;
end $$;

-- Every RLS policy in 0001 filters on user_id, so each of these tables is queried as
-- `where user_id = auth.uid()` on effectively every request. Index accordingly.
create index if not exists books_user_id_idx       on public.books (user_id);
create index if not exists quotes_user_id_idx      on public.quotes (user_id);
create index if not exists vocab_words_user_id_idx on public.vocab_words (user_id);

-- local_id is the SwiftData primary key on-device. It must be unique per user so a re-install
-- or a second device can't create two remote rows that map back to the same local record.
create unique index if not exists books_user_local_idx       on public.books (user_id, local_id);
create unique index if not exists quotes_user_local_idx      on public.quotes (user_id, local_id);
create unique index if not exists vocab_words_user_local_idx on public.vocab_words (user_id, local_id);
