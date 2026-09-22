# Book Marker — Feature & Code Documentation

What every feature is for, what each type and function does, why it works the way it does, and
how the pieces fit together.

Book Marker is a SwiftUI + SwiftData iOS app for tracking books you're reading, saving quotes
from them, and building a vocabulary list. Book metadata comes from six public book APIs, and
accounts and cloud storage come from Supabase.

---

## Table of contents

1. [The main idea](#1-the-main-idea)
2. [App entry and lifecycle](#2-app-entry-and-lifecycle)
3. [Authentication](#3-authentication)
4. [Data models](#4-data-models)
5. [Book search: the multi-provider system](#5-book-search-the-multi-provider-system)
6. [The providers individually](#6-the-providers-individually)
7. [Library](#7-library)
8. [Quotes and the suggestion dropdown](#8-quotes-and-the-suggestion-dropdown)
9. [Vocabulary and dictionary lookup](#9-vocabulary-and-dictionary-lookup)
10. [Cover images](#10-cover-images)
11. [Cloud sync — written but not wired up](#11-cloud-sync--written-but-not-wired-up)
12. [The Supabase backend](#12-the-supabase-backend)
13. [Configuration and secrets](#13-configuration-and-secrets)
14. [Dead code and known gaps](#14-dead-code-and-known-gaps)

---

## 1. The main idea

Three ideas run through the whole codebase:

**Local-first.** Everything the user creates lives in SwiftData on the device. The app is fully
usable with no network and no account — books, quotes and words all read and write locally. The
cloud is meant to be a backup and a way to move between devices, not the source of truth.

**No single point of failure in book data.** Rather than depending on one book API, the app
queries six and merges the answers. Any provider can be slow, rate-limited, unconfigured, or
entirely down, and the search still returns whatever the others found. A provider failure is
never an error the user sees — it is simply fewer results.

**Failures are silent, not loud.** Across search and suggestions, an empty result and a total
outage look identical to the user: no error dialog, no "something went wrong" panel, just no
dropdown. This is deliberate. The user cannot act on "Library of Congress timed out", so telling
them is noise.

---

## 2. App entry and lifecycle

### `BookMarkerApp` (`BookMarkerApp.swift`)

The `@main` entry point. Its one real job is building the SwiftData `ModelContainer` for the
three models (`Book`, `Quote`, `VocabWord`) and injecting it into the view tree.

**Why the unusual `init`:** container creation is wrapped in a `do/catch` that, on failure,
**deletes the local store** (plus its `-wal` and `-shm` sidecar files) and tries again. SwiftData
throws when the on-disk schema no longer matches the code — which happens every time a property
is added to a model without a migration plan. Rather than crash on launch during development,
the app resets local storage.

> **This is a development-time convenience with a real cost.** It silently destroys all local
> data on any schema change. The comment claims data "will be restored from Supabase on next
> sync", but sync is never actually invoked (see §11), so today this is unrecoverable data loss.
> Before release this needs a real `SchemaMigrationPlan`.

### `ContentView`

The root view and the authentication gate. It renders one of three things:

| State | Shown | Why |
|---|---|---|
| `isRestoringSession` | `launchPlaceholder` | A stored session is still being read from the Keychain |
| `isAuthenticated` | `mainTabView` | Signed in |
| otherwise | `AuthView` | Signed out |

**Why the three-way split instead of two:** `currentUser` is `nil` both when the user is signed
out *and* during the moment before a persisted session has loaded. Treating those as the same
thing made every returning user see the login screen flash before being dropped into the app.
The placeholder distinguishes "we don't know yet" from "definitely signed out".

`mainTabView` is a three-tab `TabView` — Library, Quotes, Vocab — with a gear button in the
Library toolbar leading to `SettingsView`.

---

## 3. Authentication

### `AuthManager` (`Services/AuthManager.swift`)

A singleton `@Observable` class wrapping the Supabase auth client. Owns the one `SupabaseClient`
instance the whole app shares.

**`currentUser` / `isAuthenticated`** — the observable signal the UI gates on.

**`isRestoringSession`** — true until the stored session has been read back at launch. See the
table above for why this exists.

**The `authStateChanges` loop (in `init`)** — this is *also* how persistent login works.
supabase-swift stores the session in the iOS Keychain and refreshes the access token in the
background on its own; on launch it replays the restored session into this stream as an
`.initialSession` event. There is no manual "restore session" call anywhere, and none is needed.
The app's only responsibility is to wait for that event before concluding the user is signed
out. A 5-second failsafe task clears `isRestoringSession` regardless, so a Keychain read failure
can never strand the user on a spinner.

**`signInWithApple()`** — runs the *native* Sign in with Apple flow:

1. Generate a random nonce (`makeRandomNonce`, drawing on the OS CSPRNG via
   `SystemRandomNumberGenerator`).
2. Hand Apple only the nonce's SHA-256 hash (`request.nonce`).
3. Present the Apple sheet and receive an identity token.
4. Send the token **and the raw nonce** to Supabase via `signInWithIdToken`.

**Why the nonce matters:** it binds the identity token to this one sign-in attempt. Apple embeds
the hash in the token; Supabase re-hashes the raw value and compares. Without it, a token
captured anywhere could be replayed to mint a session.

**Why it's `signInWithIdToken` and not `signInWithOAuth`:** this is the native flow, where the
token is minted on-device. Supabase validates the token's `aud` claim against its configured
Apple client IDs, and for native iOS `aud` is the **bundle ID** (`com.bookmarker.app`). The
web-style `/auth/v1/callback` redirect URL and an Apple Services ID / `.p8` key are for
`signInWithOAuth` and are not used by this app.

**`performAppleSignIn(rawNonce:)`** — bridges `ASAuthorizationController`'s delegate callbacks
into `async/await` with a `CheckedContinuation`. Sets both `delegate` and
`presentationContextProvider`; the latter tells the controller which window to anchor its sheet
to, and without it the flow fails with a bare `AuthorizationError 1000`.

**`signUpWithEmail` / `signInWithEmail`** — thin pass-throughs to Supabase.

**`signOut()`** — calls Supabase, which clears the Keychain-stored session. The app deliberately
does **not** implement a second manual Keychain layer on top.

**`deleteAccount()`** — invokes the `delete-account` Edge Function, then signs out locally.

**Why an Edge Function rather than a direct call:** deleting a row from `auth.users` requires the
`service_role` key, which bypasses RLS entirely. That key must never ship inside a client app.
The function runs server-side, authenticates the caller by their own JWT, and uses the privileged
key only there.

**`ASAuthorizationControllerDelegate` extension** — extracts the identity token on success. On
`.canceled` it resumes with a private `AuthManagerError.appleSignInCanceled`, which
`signInWithApple` catches and swallows, so dismissing the Apple sheet is not treated as an error.

### `AuthView` (`Views/AuthView.swift`)

The sign-in / sign-up form: an Apple button, email and password fields with inline validation,
and a toggle between sign-in and sign-up modes.

**`validateEmail` / `validatePassword`** — take an `updateUI` flag so the same rules can drive
both the live inline error text and the `isFormValid` check that enables the submit button,
without the act of checking validity writing to state.

**`handleError(_:)`** — maps known error strings to specific, actionable messages
(`invalid_credentials`, `user already registered`, `email_not_confirmed`, rate limits, disabled
provider, `ASAuthorizationError`) and falls back to a generic sentence. Logs the underlying error
under `#if DEBUG`.

**Why both:** server error text can leak internals, so it should not reach the UI — but with
*nothing* logged, every distinct failure looked identical and had to be diagnosed by elimination
against the live API. The debug log keeps the real cause visible to developers only.

**A structural oddity worth knowing about:** the Apple button is a `SignInWithAppleButton` with
empty `onRequest`/`onCompletion` closures, covered by a transparent `Button` overlay that calls
`handleAppleSignIn()`. This exists because `SignInWithAppleButton` has no plain action closure,
and the real flow lives in `AuthManager`. It works, but it is fragile — the visible control and
the control that actually does something are different views.

### `SettingsView`

Sign out and delete account, each wrapping the corresponding `AuthManager` call with an
`isProcessing` flag and an error alert. Account deletion is destructive and irreversible, so it
is confirmation-gated in the UI.

---

## 4. Data models

All three are SwiftData `@Model` classes in `Models/`.

### `Book`

`id`, `title`, `author`, `coverID`, `coverURLString`, `olid`, `shelf`, `dateAdded`,
`coverImageData`.

- **`coverID` vs `coverURLString`** — Open Library addresses covers by a numeric ID; every other
  provider gives a direct URL. Both are kept so either style works.
- **`olid`** — the Open Library Work ID (`/works/OL12345W`). Used to fetch quote suggestions.
  Only ever populated for books added *from* Open Library (see §8 for why that matters).
- **`coverImageData`** — the downloaded cover, stored on the model so it loads instantly on
  later launches with no network.

### `Shelf`

A `String`-backed enum: `Reading`, `Bucket List`, `Done`. The raw values are what get persisted
and sent to Postgres, so the database has a matching `CHECK` constraint.

### `Quote`

`text`, `bookTitle`, `bookID`, `pageNumber`, `note`, `dateAdded`.

**Why both `bookTitle` and `bookID`:** `bookID` links the quote to a `Book` in the library, but
`bookTitle` is kept as plain text as well, so a quote survives its book being deleted and so
quotes saved before `bookID` existed still display correctly.

### `VocabWord`

`word`, `definition`, `bookID`, `pageNumber`, `note`, `dateAdded`. Same book-association
reasoning as `Quote`.

### Sync fields (all three models)

- **`remoteID`** — the row's UUID in Supabase. `nil` means never synced.
- **`needsSync`** — local changes not yet pushed. Set `true` in every `init`.
- **`updatedAt`** — drives last-write-wins conflict resolution.

These are written by the model initializers but nothing currently reads them at runtime — see
§11.

---

## 5. Book search: the multi-provider system

This is the most architecturally interesting part of the app.

### The idea

Six independent providers, each wrapping one public book API. All are queried **in parallel**,
their results merged and deduplicated. No provider is privileged, and any can fail without
affecting the others.

**Why parallel rather than sequential fallback:** a sequential "try Google, then Open Library,
then…" chain pays the cost of every failure *in series* — three dead providers at 5 seconds each
is a 15-second search. Fanning out means the total time is that of the slowest provider you're
still willing to wait for, regardless of how many fail.

### `BookProvider` (protocol)

The contract every provider implements:

| Member | Purpose |
|---|---|
| `id` | Which provider this is (`BookProviderID`) |
| `isAvailable` | Whether it's usable right now — `false` for one needing unconfigured credentials |
| `searchBooks(query:)` | Free-text search |
| `findBook(isbn:)` | Direct ISBN lookup |
| `bookDetails(providerID:)` | Full details for a previously returned result |
| `searchInsideBook(providerID:query:)` | Full-text search within a book |
| `fullText(providerID:)` | Legally available full text, when permitted |

**Why the protocol extension supplies defaults** (`isAvailable = true`, and `nil`/`[]` for the
last three): most providers only support metadata search. Without defaults, every provider would
need boilerplate stubs for capabilities it doesn't have. A metadata-only provider implements two
methods and inherits sensible "unsupported" answers for the rest.

`BookProviderError` distinguishes *"this provider has nothing to say"* from *"a real network
failure"*, so the coordinator can decide whether something is worth surfacing.

### `BookSearchCoordinator` (actor)

**`searchAll(query:)`** — the main entry point.

1. Trim the query; return early if empty.
2. Open a `TaskGroup` and add one task per available provider.
3. Wrap each provider call in `withDeadline(seconds:fallback:)`.
4. Wrap the result in `(try? await …) ?? []` so any thrown error becomes an empty array.
5. Collect everything, then `deduplicate`.

**`withDeadline(seconds:fallback:)`** — races the real work against a `Task.sleep` in a nested
task group. Whichever finishes first wins; the loser is cancelled. The sleep branch returns
`nil`, which is how "the deadline fired" is distinguished from "the provider legitimately
returned nothing".

**Why a deadline at all,** given `ProviderSession` already sets timeouts: the URL timeout (8s) is
a backstop for a hung socket. The 5-second deadline is the *interactive* budget — search-as-you
type is worthless if it outlasts the user's patience, and a merely-slow provider is
indistinguishable from a dead one as far as the dropdown is concerned.

**Deduplication.** Matching preference is **ISBN-13 > ISBN-10 > normalized title+author**.

- `dedupKey(for:)` builds the grouping key from the best identifier available.
- `normalize(_:)` lowercases, strips diacritics, and reduces to alphanumeric words, so
  "The Hobbit" and "the hobbit," group together.
- `best(of:)` picks the group's representative: prefer confirmed full text, then a cover image,
  then richer metadata (`fieldCount`), then a fixed provider priority order.

**Why identity is never assumed without an ISBN:** two different editions can share a title and
author. The title+author tier only groups results that *also* share a first author, and even then
keeps the richest one rather than discarding the others' detail arbitrarily.

### `ProviderSession`

A shared `URLSession` with `timeoutIntervalForRequest = 8` and `timeoutIntervalForResource = 12`,
`httpMaximumConnectionsPerHost = 6`, and `waitsForConnectivity = false`.

**Why it exists:** `URLSession.shared` defaults to a **60-second** request timeout. Because the
coordinator waits for the whole task group, one unreachable provider held every search open for a
full minute. Every provider, plus `BookContentService` and `EdgeFunctionClient`, uses this
session instead. `DictionaryService` deliberately does not — it isn't part of the search fan-out.

The raised per-host connection cap matters because providers run concurrently; the default of 4
would serialize requests that happen to share a host.

### `BookSearchModels`

- **`BookProviderID`** — enum of the seven known providers, with `displayName` for the UI.
- **`ContentAvailability`** — `metadataOnly` / `previewOnly` / `fullTextAvailable`. Drives what
  the detail sheet offers.
- **`RightsInformation`** — public-domain flag, license, statement.
- **`BookSearchResult`** — the normalized shape every provider maps its response into. Its
  `olid` computed property is `provider == .openLibrary ? providerID : nil`, which is the single
  most consequential line in the file (see §8).

---

## 6. The providers individually

| Provider | API | Auth | Notes |
|---|---|---|---|
| `OpenLibraryService` | openlibrary.org | none | The richest provider. Also supplies `searchInsideBook` and cover downloads |
| `GutendexProvider` | gutendex.com | none | Project Gutenberg. Implements `fullText` — everything it serves is public domain |
| `InternetArchiveProvider` | archive.org | none | Implements `bookDetails` |
| `LibraryOfCongressProvider` | loc.gov | none | Metadata only |
| `GoogleBooksProvider` | via Edge Function | user JWT | Key-gated |
| `EuropeanaProvider` | via Edge Function | user JWT | Key-gated |
| `HathiTrustProvider` | hathitrust.org | none | Keyless Bibliographic API only |

### Why two providers go through Edge Functions

Google Books and Europeana require API keys. A key shipped inside an iOS app is extractable from
the binary — it is not a secret. So those two providers call
`EdgeFunctionClient.invoke(_:query:)`, which hits a Supabase Edge Function that holds the key
server-side and proxies the request.

**`EdgeFunctionClient.invoke`** attaches the user's access token as `Authorization: Bearer` and
the publishable key as `apikey`, then decodes the JSON response. If there is no current session
it returns `nil` rather than throwing — an unauthenticated user simply gets no results from these
two providers, which the coordinator treats like any other empty result.

The Edge Functions themselves (`supabase/functions/search-google-books`, `search-europeana`)
require an authenticated user, cap query length, call only a fixed upstream endpoint — never a
caller-supplied URL — and never forward the upstream's raw error body, which could echo the key
back.

---

## 7. Library

### `LibraryView`

The book shelf. `@Query` fetches all books sorted by `dateAdded` descending; `booksOnShelf`
filters to the selected shelf in memory.

- `shelfPicker` — segmented control over `Shelf.allCases`.
- `emptyShelfView` — shown when a shelf has no books.
- `bookGrid` — adaptive `LazyVGrid` of `BookGridCell`s.
- Hosts `SpotlightSearchOverlay` for adding books.

### `SpotlightSearchOverlay`

A Spotlight-style search panel over the current screen.

**`scheduleSearch(for:)`** — cancels any in-flight task, returns early on an empty query, then
starts a task that sleeps **400ms** before searching. This is debouncing: without it, every
keystroke would fire six API calls.

**`performSearch(query:)`** — `@MainActor`, calls `BookSearchCoordinator.searchAll`.

**The content section renders nothing when there are no results** — no error panel, no "no
results" message. "Nothing matched" and "every provider is down" are intentionally
indistinguishable; the dropdown simply doesn't appear.

### `BookDetailSheet`

Shown when a search result is tapped. Displays cover, metadata, and a shelf selector, then
`saveBook()` constructs a `Book` from the `BookSearchResult` and inserts it into the model
context. `alreadySaved` prevents duplicates.

---

## 8. Quotes and the suggestion dropdown

### `QuotesView`

Lists saved quotes with search filtering, an empty state, and `QuoteRow` cells.

### `AddQuoteView`

Two-phase: pick a book from the Reading shelf, then type the quote. If the Reading shelf is
empty it alerts and dismisses — a quote must belong to a book.

**`updateSuggestions(for:)`** — `@MainActor`. Cancels any in-flight task, requires **≥3
characters**, snapshots the selected `Book` into a `BookContentService.BookRef`, then starts a
task that debounces **300ms** before asking for suggestions.

**Why the snapshot:** `Book` is a SwiftData `@Model` — a reference type that is neither
`Sendable` nor safe to touch off its owning context. Passing one into an actor is a concurrency
violation. `BookRef` is a plain `Sendable` struct of `olid`/`title`/`author` with a `@MainActor`
initializer, so the hop off the main actor carries only immutable strings.

### `BookContentService` (actor)

Supplies the autocomplete candidates.

**Why an actor:** `prewarm` fans out one task per book and every one writes the `cache`
dictionary. As a plain class that was an unsynchronized read-modify-write from several tasks at
once — a real data race, and concurrent `Dictionary` mutation can corrupt its internal storage,
not merely lose a write. Actor isolation serializes all cache access.

**`suggestions(for:matching:)`** — resolves a work key, fetches (or reuses cached) candidates,
and filters them by substring match against the user's input.

**`workKey(for:)`** — the important one. If `book.olid` is present, use it. Otherwise look the
work up in Open Library by title and author and cache the answer, *including* a negative result.

**Why this fallback is necessary:** `BookSearchResult.olid` is
`provider == .openLibrary ? providerID : nil`, so only books added from Open Library have one.
And because the coordinator dedupes across providers and keeps whichever result is *richest*, a
book that exists on Open Library can still be added from Google Books because that result looked
better. Without the fallback, suggestions worked or didn't for no reason the user could see or
influence.

**`fetchCandidates(olid:bookTitle:author:)`** — hits the Open Library Works API and assembles
candidates from four sources: description sentences, table-of-contents titles, subjects longer
than 8 characters, and excerpts. Deduplicates via `NSMutableOrderedSet` and drops anything under
12 characters.

**`splitIntoSentences(_:)`** — uses `enumerateSubstrings(in:options: [.bySentences, .localized])`
rather than splitting on `.`, so abbreviations and quotation marks don't produce fragments.

> **An honest limitation:** these candidates are book *metadata* — blurbs, chapter titles,
> subjects — not the actual prose of the book. Open Library does not serve full text. Real
> "quote from the book" autocomplete would need `searchInsideBook` (Open Library and Internet
> Archive implement it) or `fullText` (Gutendex), neither of which this path currently uses.

---

## 9. Vocabulary and dictionary lookup

### `VocabView`

Mirrors `QuotesView`: filtered list, empty state, `VocabWordRow` cells.

### `AddWordView`

**`triggerLookup(word:)`** — debounces **700ms** (longer than search's 400ms, because a
dictionary lookup only makes sense on a complete word) then calls `fetchDefinition`.

**`fetchDefinition(for:)`** — `@MainActor`. Calls `DictionaryService`, and on success
**overwrites `wordText` with the API's spelling** to normalize casing. Both success and failure
paths re-check `Task.isCancelled` before writing state, so a stale in-flight lookup can't
clobber a newer one.

### `DictionaryService`

Wraps `api.dictionaryapi.dev`. `fetchDefinition(for:)` percent-encodes the word, requires HTTP
200, decodes the nested response, and returns the first meaning's first definition as a flat
`DictionaryResult`.

**Why flatten:** the API returns every meaning and every sense. The add-word form has one
definition field, so the service collapses the structure at the boundary rather than pushing that
decision into the view.

`DictionaryError` provides user-facing text via `LocalizedError`.

---

## 10. Cover images

### `CoverImageCache` (`@MainActor`)

**`image(for:size:)`** — returns the cached `coverImageData` if present; otherwise downloads
(preferring `coverURLString`, falling back to the `coverID` path), **writes the bytes back onto
the `Book` model**, and returns the image.

**Why store image data in the database:** covers are small, never change, and are shown in a
scrolling grid. Persisting them on the model means later launches render instantly with no
network and no separate cache layer to invalidate.

**Why `@MainActor`:** it mutates a SwiftData model, which must happen on the context's actor.

`CachedCoverImageView` and `CoverImageView` are the SwiftUI wrappers, with
`placeholderView(size:)` for books with no cover.

---

## 11. Cloud sync — written but not wired up

> **`SyncManager.syncUp` and `syncDown` are never called anywhere in the app.** The entire sync
> layer is dead code today. Nothing is ever uploaded to or downloaded from Supabase; `needsSync`
> is set to `true` by every model initializer and never read again. The app is currently
> local-only in practice, regardless of whether the user is signed in.

What exists and is ready to be used:

### `SyncManager` (actor)

**Why an actor:** `syncUp` and `syncDown` could otherwise interleave — foreground refresh and a
background trigger at once — corrupting the in-flight record list or issuing duplicate upserts.
The serial executor gives mutual exclusion without manual locks.

**`NWPathMonitor`** — both methods return early when offline, so being offline is a no-op rather
than a thrown error surfacing in the UI.

**`syncUp(modelContext:)`** — fetches records where `needsSync == true`, assigns a `remoteID` to
any that lack one, maps them to the DTOs, and `upsert`s with `onConflict: "id"`. Clears
`needsSync` and saves the context.

`remoteBookID(forLocalBookID:)` resolves a quote's or word's owning book to a **remote** ID,
assigning one if the book hasn't synced yet, so the foreign key is valid server-side even when
the book itself hasn't been pushed.

**`syncDown()`** — fetches all rows for the user and maps them back into model instances. It
deliberately does **not** insert them into a context; the caller merges. `remoteToLocalBookID`
translates server-side `book_id` foreign keys back to local SwiftData IDs.

**Conflict resolution** is last-write-wins on `updatedAt` — a documented simplification. Two
offline devices editing the same record will silently lose one edit, and field-level merges
aren't handled.

### The DTOs

`RemoteBook`, `RemoteQuote`, `RemoteVocabWord` — `Codable` structs whose `CodingKeys` map Swift
camelCase to Postgres snake_case. **These are the real schema contract**; the migrations were
derived from them.

---

## 12. The Supabase backend

### Migrations (`supabase/migrations/`)

| File | Purpose |
|---|---|
| `0000_create_base_tables.sql` | Creates `books`, `quotes`, `vocab_words` |
| `0001_enable_rls_and_ownership_policies.sql` | Enables and forces RLS, adds ownership policies |
| `0002_book_association_and_cover_url.sql` | Adds `cover_url`, `book_id`, `page_number`, `note` |
| `0003_least_privilege_grants.sql` | Strips `anon` grants, grants `authenticated` exactly CRUD |

**The threat model `0001` defends against:** the app ships a publishable key, which is extractable
from the binary and is *designed* to be public. Anyone holding it can send arbitrary requests to
the Data API as `anon` or `authenticated`. **RLS — not key secrecy — is what stops that key from
reading other users' rows.**

Policies are `auth.uid() = user_id` for all four verbs. `UPDATE` carries **both** `USING` and
`WITH CHECK`: `USING` alone would let a user update a row they own while silently reassigning its
`user_id` to someone else. RLS is also `FORCE`d so even the table owner is subject to policies.

**Why `0003` exists on top of RLS:** Postgres checks GRANTs *before* any policy is evaluated. A
role with no grant is denied outright. Revoking everything from `anon` and `public` means
unauthenticated requests never even reach the policy layer.

### Edge Functions (`supabase/functions/`)

- **`search-google-books`** / **`search-europeana`** — hold the API keys server-side, require an
  authenticated user, cap query length, call one fixed upstream endpoint, and never forward the
  upstream's raw error body.
- **`delete-account`** — the only privileged operation, using `service_role` server-side.

### Tests

`supabase/tests/rls_tests.sql` exercises the ownership policies.

---

## 13. Configuration and secrets

### `SupabaseConfig` (`Services/Config.swift`)

Reads `SupabaseProjectRef` and `SupabaseAnonKey` from the `Info.plist`, which maps them from
build settings, which come from the gitignored `Secrets.xcconfig`. Both are `fatalError` on
absence — a missing config is a build misconfiguration, not a recoverable runtime state.

**Why only the project *ref* and not a full URL:** xcconfig treats `//` as a comment marker, so a
URL scheme can't survive in that file. The ref is stored and the URL built in Swift.

**What belongs where:**

| Credential | Location | Why |
|---|---|---|
| Project ref, publishable key | `Secrets.xcconfig` | Client-side safe; RLS is the real boundary |
| `GOOGLE_BOOKS_API_KEY`, `EUROPEANA_API_KEY` | Supabase Edge Function secrets | Extractable from a binary; must stay server-side |
| `service_role` / secret key | Supabase only, never the app | Bypasses RLS entirely |

---

## 14. Dead code and known gaps

**Dead code**

- **`SyncManager`** — fully implemented, never called (§11).
- **`SearchView`** (`Views/Search/SearchView.swift`) — the `SearchView` struct is never
  referenced; `SpotlightSearchOverlay` replaced it. **However, `SearchResultRow` lives in the
  same file and is used by the overlay, so the file cannot simply be deleted.** `SearchView` also
  still contains the `errorView` and `emptyResultsView` panels that were removed from the
  overlay.
- **`Todo.swift`** — a `Todo` struct referenced nowhere. Leftover scaffolding.

**Gaps**

- No `SchemaMigrationPlan`; a schema change wipes local data (§2).
- Quote suggestions draw on metadata, not book prose (§8).
- `pageNumber` and `note` exist on the models, in the DTOs, and in the database, but no UI
  collects them.
- Neither key-gated Edge Function has caching or rate limiting.
- Email confirmation is currently disabled for testing and must be re-enabled before release.
