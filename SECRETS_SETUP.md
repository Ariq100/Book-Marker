# Secrets Setup

Exact, step-by-step instructions for configuring every credential Book Marker uses. Follow the
**"Where it goes"** line precisely — that's the only place each value should ever be pasted.

No credential in this document should ever be pasted into a Swift file, `Info.plist`, or
anything else that ships inside the iOS app, except the two explicitly marked "client-side safe"
in Step 1.

---

## Step 1 — Supabase client-side configuration (iOS app)

This is the only place credentials belong *in the app itself*.

1. Open (or create) `Secrets.xcconfig` at the project root. It's gitignored — it should never be
   committed.
2. Paste:
   ```
   SUPABASE_PROJECT_REF = your-project-ref
   SUPABASE_ANON_KEY = sb_publishable_xxxxxxxxxxxxxxxxxxxxxxxx
   ```
   - `SUPABASE_PROJECT_REF`: from your Supabase dashboard URL, `https://supabase.com/dashboard/project/<this-part>`.
   - `SUPABASE_ANON_KEY`: **the publishable key** (starts `sb_publishable_...`), from
     **Project Settings → API Keys**. This key is designed to be public/client-side safe — RLS
     (migration `0001_enable_rls_and_ownership_policies.sql`) is what actually protects data, not
     keeping this key secret.
3. **Never** put `SUPABASE_SECRET_KEY`, `sb_secret_...`, or a legacy `service_role` key here or
   anywhere else in the Xcode project. If you're not sure why, see `SECURITY.md`.

---

## Step 2 — Link the Supabase CLI to your project

Run once, locally (not in the app):

```bash
brew install supabase/tap/supabase   # if you don't have the CLI yet
supabase login
supabase link --project-ref your-project-ref
```

## Step 3 — Apply the database migrations

```bash
supabase db push
```

This runs everything in `supabase/migrations/` against your live project: enables RLS, creates
the ownership policies, adds the book-association/cover-URL columns, and tightens PostgreSQL
grants. Safe to re-run — every statement is idempotent.

## Step 4 — Google Books API key (optional — only needed for the Google Books provider)

1. **Is it required?** Only if you want `GoogleBooksProvider` to return results. The app works
   fine without it — that provider just returns no results until configured.
2. **Is it free?** Yes, with a usage quota; billing can be enabled for higher limits.
3. **Where to register:** https://console.cloud.google.com/apis/credentials
   - Create/select a Google Cloud project → **Enable APIs** → search "Books API" → Enable.
   - **Credentials → Create Credentials → API key.**
4. **Where to obtain the key:** the API key shown immediately after creation in that same
   Credentials page.
5. **Where it goes:** *never* in Xcode. Set it as a Supabase Edge Function secret:
   ```bash
   supabase secrets set GOOGLE_BOOKS_API_KEY=paste-your-key-here
   ```
6. **Which Edge Function uses it:** `supabase/functions/search-google-books`.

## Step 5 — Europeana API key (optional — only needed for the Europeana provider)

1. **Is it required?** Only for `EuropeanaProvider`. Optional, same graceful-degradation as above.
2. **Is it free?** Yes.
3. **Where to register:** sign in / create an account at https://www.europeana.eu/en, then request
   a key from the account section (registration for keys moved there as of May 2025) — or via
   https://pro.europeana.eu/page/get-api.
4. **Where to obtain the key:** shown in your Europeana account after the request is approved
   (usually instant).
5. **Where it goes:**
   ```bash
   supabase secrets set EUROPEANA_API_KEY=paste-your-key-here
   ```
6. **Which Edge Function uses it:** `supabase/functions/search-europeana`.

## Step 6 — HathiTrust (not currently needed)

`HathiTrustProvider.swift` uses HathiTrust's free, keyless Bibliographic API directly — **no
secret required**. A `HATHITRUST_API_KEY` placeholder exists in `.env.example` only for if you
later integrate HathiTrust's full-text Data API, which requires a signed institutional agreement
(see https://www.hathitrust.org/). Do not set this unless you've completed that process.

## Step 7 — Deploy the Edge Functions

```bash
supabase functions deploy search-google-books
supabase functions deploy search-europeana
supabase functions deploy delete-account
```

## Step 8 — Verify a secret is NOT returned to the client

```bash
curl -i "https://your-project-ref.supabase.co/functions/v1/search-google-books?q=dune" \
  -H "Authorization: Bearer <a real user access token>" \
  -H "apikey: <your publishable key>"
```

Inspect the JSON response body — it should contain only `title`, `authors`, `coverImageURL`,
etc. If `GOOGLE_BOOKS_API_KEY` ever appears in a response body, that's a bug in the function —
file it immediately and rotate the key.

## Step 9 — Verify no secret is present in the iOS binary or repo

```bash
# Repo-wide (should return nothing except this file's placeholder lines and docs):
grep -rniE "sb_secret_|service_role|GOOGLE_BOOKS_API_KEY=.+|EUROPEANA_API_KEY=.+" \
  --include="*.swift" --include="*.plist" --include="*.xcconfig" --include="*.pbxproj" .

# Built binary (after an Xcode build), swap in your actual DerivedData path:
strings "/path/to/DerivedData/.../Book Marker.app/Book Marker" | grep -iE "sb_secret_|GOOGLE_BOOKS_API_KEY|EUROPEANA_API_KEY"
```

Both commands should produce no matches. If either does, treat the matched credential as
compromised and rotate it (see `SECURITY.md` → "Rotating a credential").

---

## Local development

If you want to run functions locally with `supabase functions serve`:

```bash
cp .env.example .env       # then fill in real values in .env — NEVER commit this file
supabase functions serve --env-file .env
```

`.env` is gitignored (`.gitignore` excludes `.env` and `.env.*`, but keeps `.env.example`).
