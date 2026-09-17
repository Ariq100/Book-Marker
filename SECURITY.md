# Security Architecture

## Incident note (read first)

A Supabase secret/service_role-style key was shared in this project's chat history while working
with an AI assistant. **A full repo, git-history, and build-artifact scan found no complete
secret key value anywhere in the codebase** — the values that appeared in chat were dashboard's
own truncated/redacted display strings, and `.env` (the one file that ever referenced a secret
key locally) was never committed. That said, **treat any credential that has ever passed through
a chat transcript as burned**, regardless of whether it was full or truncated. Rotate it:

1. Supabase dashboard → your project → **Project Settings → API Keys**.
2. Under **Secret keys**, find the key you're rotating and use the dashboard's **rotate/revoke**
   action for that specific key (this immediately invalidates the old value; anything still using
   it will start failing, which is the point).
3. If you have server-side code depending on the secret key (this project's Edge Functions use
   `auth: 'secret'`/`ctx.supabaseAdmin`, which resolve the current key automatically — see
   `.agents/skills/supabase-server/SKILL.md`), no code change is needed after rotation; Supabase
   resolves the active key server-side.
4. Never paste the new key back into a chat, issue, PR description, or commit. It only ever goes
   into Supabase's own secret storage (`supabase secrets set ...`) — see `SECRETS_SETUP.md`.

---

## The two rules that matter most

1. **A malicious user who extracts the iOS app's public key must not be able to read, modify, or
   delete another user's data.** That's RLS's job, not the key's. See "RLS architecture" below.
2. **No secret/service_role key or private third-party API key may ever ship inside the iOS
   app.** Privileged operations go through a Supabase Edge Function instead. See "Edge Function
   security" below.

## Supabase key model

| Key | Where it lives | Safe in iOS app? |
|---|---|---|
| `SUPABASE_PROJECT_REF` + publishable key (`sb_publishable_...`) | `Secrets.xcconfig` (gitignored) | **Yes** — designed to be public; RLS is the real boundary |
| Secret key (`sb_secret_...`, formerly "service_role") | Supabase Edge Function secrets only | **Never** |
| `GOOGLE_BOOKS_API_KEY`, `EUROPEANA_API_KEY` | Supabase Edge Function secrets only | **Never** |

The legacy `anon`/`service_role` key names are being phased out by Supabase in favor of
publishable/secret keys; this project uses the current terminology throughout
(`SUPABASE_ANON_KEY` in `Secrets.xcconfig`/`Config.swift` is named for source compatibility with
the existing `Info.plist` key `SupabaseAnonKey`, but its *value* is the modern publishable key).

## RLS architecture

Every user-owned table (`books`, `quotes`, `vocab_words`) has:

- Row Level Security **enabled and forced** (`ENABLE ROW LEVEL SECURITY` + `FORCE ROW LEVEL
  SECURITY`), so even a privileged Postgres role must go through policies.
- Four policies — SELECT/INSERT/UPDATE/DELETE — each requiring `auth.uid() = user_id`.
- `WITH CHECK` (not just `USING`) on INSERT and UPDATE, which is what actually stops a client
  from inserting a row under someone else's `user_id`, or updating their own row and quietly
  reassigning it to another user's `user_id`. `USING` alone only controls which *existing* rows
  a query can touch — it does not constrain what the resulting row is allowed to look like.
- No policy at all for the `anon` role: with RLS forced, "no matching policy" means deny by
  default, so unauthenticated requests get zero rows and every write is rejected.
- `user_id` defaults to `auth.uid()` and has a `NOT NULL` FK to `auth.users(id) ON DELETE
  CASCADE`, so deleting a user's auth account cleans up their data automatically (see the
  `delete-account` Edge Function).

See `supabase/migrations/0001_enable_rls_and_ownership_policies.sql`.

**RLS is checked after PostgreSQL GRANTs, not instead of them.** Migration
`0003_least_privilege_grants.sql` revokes all default/anon grants on these tables and grants
`authenticated` exactly `SELECT, INSERT, UPDATE, DELETE` — no `TRUNCATE`, no ownership of the
tables themselves.

## Database ownership model

`Quote.bookID` / `VocabWord.bookID` (migration `0002`) reference `books.id` with `ON DELETE SET
NULL` — deleting a book un-links but doesn't delete the quotes/words saved from it. This FK
doesn't need its own RLS policy: the existing `user_id` policies already restrict every row (and
therefore every `book_id` a user could legitimately reference) to that user's own data.

## Storage security

**Not currently used.** No Supabase Storage bucket exists in this project — book covers are
either fetched live from a provider's own CDN (`coverImageURL`) or cached locally as `Data` on
the SwiftData `Book` model, never uploaded to Supabase. If a future feature adds user file
uploads (e.g. a custom cover photo, an OCR scan), it must ship with:
- A private (non-public) bucket.
- Storage RLS policies keyed on `auth.uid()` matching a path prefix (e.g.
  `storage.foldername(name)[1] = auth.uid()::text`), not just bucket-level access.
- The same "own files only" SELECT/INSERT/UPDATE/DELETE structure as the database tables above.

## Edge Function security

All three functions (`search-google-books`, `search-europeana`, `delete-account`) use
`@supabase/server`'s `auth: 'user'` mode, which:
- Requires and verifies a real Supabase user JWT before the handler runs (unauthenticated
  requests never reach the function body).
- Handles CORS automatically.

None of them is a generic proxy. Each calls exactly one fixed, hardcoded upstream URL
(`googleapis.com/books/v1/volumes`, `api.europeana.eu/record/v2/search.json`) — the caller can
influence the *query string* sent to that fixed endpoint, never the destination host. There is no
`fetchURL(userProvidedURL)`-style endpoint anywhere in this project.

Query length is capped (`MAX_QUERY_LENGTH`) before any upstream call is made. Upstream error
bodies are never forwarded verbatim to the client — they're replaced with a generic message, so a
misbehaving upstream API can't be used to leak its own error text (which occasionally echoes
request parameters) back through this app.

`delete-account` never accepts a user id in the request body — it only ever deletes
`ctx.supabase.auth.getUser()`'s own id, so there's no way to delete another account by tampering
with the request.

## Secret management rules

- Real secrets live in exactly one place: `supabase secrets set KEY=value` (see
  `SECRETS_SETUP.md`). Never in Swift, `Info.plist`, `.xcconfig`, or committed `.env` files.
- `.gitignore` excludes `Secrets.xcconfig`, `.env`, and `.env.*` (with `.env.example` explicitly
  un-ignored, since it only contains placeholders).
- `.env.example` must only ever contain empty placeholders — never real values, even temporarily.

## Copyright / content-access rules

See `BOOK_API_PROVIDERS.md` for the per-provider breakdown. The governing principle: `
ContentAvailability.fullTextAvailable` is only ever set when a source's own rights/access data
confirms it (public-domain Gutenberg/Internet Archive items with a real OCR text file present) —
never inferred from the mere existence of search metadata. Everything else defaults to
`.metadataOnly`/`.previewOnly`/`.unavailable`. No provider bypasses lending restrictions, DRM, or
paywalls. For books without a legal full-text source, the architecture instead supports
`.userProvidedText` and `.ocrCaptured` (the latter intended for a future Vision-framework OCR
capture flow of the user's own physical copy — not yet built).

## How to rotate an API key

1. **Supabase secret key**: dashboard → Project Settings → API Keys → rotate/revoke, as described
   in "Incident note" above.
2. **Google Books / Europeana key**: regenerate in that provider's console (Google Cloud
   Console / Europeana account), then `supabase secrets set GOOGLE_BOOKS_API_KEY=<new value>` (or
   `EUROPEANA_API_KEY`). No app redeploy needed — Edge Functions read the secret at request time.
3. Never requires an App Store release, since none of these keys ship in the binary.

## How to add another book provider

1. Add a case to `BookProviderID` in `BookSearchModels.swift`.
2. Create `Book Marker/Services/BookProviders/<Name>Provider.swift` conforming to `BookProvider`.
   Only implement the methods you actually support — the protocol extension supplies safe
   "unsupported" defaults for the rest.
3. If it needs a private key: never call the third-party API directly from Swift. Add a
   `supabase/functions/search-<name>/index.ts` Edge Function (copy `search-europeana` as a
   template), add the secret to `.env.example` and `SECRETS_SETUP.md`, and have the Swift
   provider call `EdgeFunctionClient.invoke(...)`.
4. Register the provider instance in `BookSearchCoordinator`'s default `providers` array.
5. Document it in `BOOK_API_PROVIDERS.md` (endpoint, auth, rate limits, full-text availability,
   rights restrictions — verify current docs, don't assume).

## How to run the RLS security tests

```bash
psql "$SUPABASE_DB_URL" -f supabase/tests/rls_tests.sql
```

Runs inside a transaction that's always rolled back (`ROLLBACK` at the end), so it's safe against
a staging database. Each check `RAISE EXCEPTION`s on failure, so "the script completes" is the
pass signal; failures name exactly which check failed. Only run against a disposable/staging
database, never production, since it inserts throwaway `auth.users` rows.

## App Store / production checklist

Done by this work:
- [x] No secret key in the client.
- [x] RLS enforced with tested ownership boundaries.
- [x] HTTPS-only network calls (no ATS exceptions added anywhere in this project).
- [x] Account deletion implemented server-side (`delete-account` function + cascading FK).
- [x] Access/refresh tokens never logged (`AuthManager.swift`'s existing no-log constraint,
      unchanged by this work).

Still requires your manual review before submission:
- [ ] Apple's App Privacy "nutrition label" declarations (what data is collected: account email,
      user-generated quotes/words/books — none of this project's code sends data to analytics or
      third parties beyond the book-metadata providers, but you still have to declare it in App
      Store Connect).
- [ ] Third-party API terms of service for each enabled provider (Google Books, Europeana) —
      verify your usage stays within their ToS at production scale.
- [ ] A production rate-limiting/quota strategy in front of the Edge Functions if usage grows
      beyond casual/personal scale (Supabase's platform-level rate limits apply, but this project
      does not add its own; see "Remaining manual security tasks" in the implementation summary).
- [ ] Confirm Sign in with Apple's redirect/callback configuration matches your production bundle
      ID and Supabase Auth provider settings.
