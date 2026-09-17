# Book API Providers

Every provider implements `BookProvider` (`Book Marker/Services/BookProviders/BookProvider.swift`)
and is independently replaceable — `BookSearchCoordinator` queries all of them concurrently and
keeps working if any one is down, slow, or unconfigured. Facts below were verified against each
provider's current official documentation as of this writing (Sept 2026), not assumed from
memory or older tutorials.

| Provider | Purpose | Endpoint(s) used | Auth | Secret required | Where to obtain | Rate limits | Full-text availability | Copyright / access limits | Caching |
|---|---|---|---|---|---|---|---|---|---|
| **Open Library** | Title/author/ISBN search, covers, experimental search-inside | `openlibrary.org/search.json`, `openlibrary.org/api/books` (ISBN), `archive.org/metadata/{id}` + `fulltext/inside.php` for search-inside | None | No | — | Not documented; app sends a descriptive `User-Agent` and avoids bulk requests per OL guidelines | Search-inside snippets only, when an associated Internet Archive scan exists (experimental, may break — OL's own docs say "can change in future") | Snippets only via search-inside; no full-page/full-book download | In-memory, session-scoped (`BookContentService`) |
| **Google Books** | Title/author/ISBN search, preview/full-text availability flags | `googleapis.com/books/v1/volumes` (via `search-google-books` Edge Function) | API key (confirmed required by current docs — "must be accompanied by an identifier") | **Yes** — `GOOGLE_BOOKS_API_KEY` | Google Cloud Console → enable "Books API" → Credentials → API key | Not published in the docs used; monitor Cloud Console quota page | `fullTextAvailable` only when `accessInfo.viewability == ALL_PAGES && publicDomain == true`; otherwise preview/metadata only | Never assumes preview access implies full text; respects `viewability`/`publicDomain` flags as returned | None yet (see "Future work" below) |
| **Internet Archive** | Metadata, digitized-book discovery, confirmed-legal OCR full text | `archive.org/advancedsearch.php` (search), `archive.org/metadata/{id}` (rights + file listing check) | None | No | — | Not documented; avoid bulk/aggressive requests per IA norms | Only when `bookDetails(providerID:)` confirms `access-restricted-item != true` **and** a `_djvu.txt` OCR file is actually listed for that item — search results themselves always default to metadata-only | Access-restricted (lending-required) items are explicitly marked unavailable, never downloaded/bypassed | None yet |
| **Gutendex (Project Gutenberg)** | Public-domain full text | `gutendex.com/books` | None | No | — | Not documented (community-run, be reasonable) | Full text whenever a `text/plain` format is listed — Gutenberg only hosts public-domain/rights-cleared works, so this is the one provider where availability can be asserted directly from search results | Never used for modern copyrighted books — the catalog itself is public-domain only | None yet |
| **Library of Congress** | Metadata/discovery, digitized-collection links | `loc.gov/search/?fo=json` | None | No | — | Not documented; app sends a `User-Agent` | Metadata only — not a full-text source | N/A (metadata only) | None yet |
| **Europeana** | Cultural-heritage metadata, legally available digital content | `api.europeana.eu/record/v2/search.json` (via `search-europeana` Edge Function) | API key (`wskey`), confirmed required by current docs | **Yes** — `EUROPEANA_API_KEY` | Free registration via Europeana account (registration moved into the account section as of May 2025) — https://pro.europeana.eu/page/get-api | Not published in the docs used | Preview only, and only when the item's own `rights` string mentions public domain — otherwise metadata only | Rights statement is read directly from Europeana's own `rights` field per item, never assumed | None yet |
| **HathiTrust** | Bibliographic metadata + rights status by identifier | `catalog.hathitrust.org/api/volumes/brief/json/isbn:{isbn}` (Bibliographic API) | None for this API (confirmed via current HathiTrust docs — "requires no authentication") | No | — | "Intended for small numbers of items at a time" per HathiTrust's own docs — this app only calls it per-ISBN lookup, never bulk | **Metadata/rights status only.** HathiTrust's actual full-text access (Data API) requires a signed institutional agreement and is intentionally **not implemented** — `fullText(providerID:)` doesn't exist on this provider | Full text is out of scope without an institutional agreement; this app never attempts to work around that | None yet |

## Providers considered and not implemented

- **HathiTrust Data API (full text):** requires institutional credentials/agreement — out of
  scope for a consumer app. If you later obtain access, add `HATHITRUST_DATA_API_*` secrets and a
  new Edge Function following the pattern in `SECURITY.md` → "How to add another book provider."

## Future work: caching

None of the direct (keyless) providers currently cache responses beyond `OpenLibraryService`'s
existing in-memory, session-scoped cache for quote-autocomplete candidates. Recommended next step
if usage grows: a small `search_cache` table (normalized query → provider → JSON result → TTL) in
Supabase, written to by the Edge Functions for the key-gated providers (Google Books, Europeana)
— those are the ones with a real rate-limit/cost concern.

## Full-text availability model

Every result carries a `ContentAvailability` (`BookSearchModels.swift`):

```
fullTextAvailable   — legally, freely accessible full text (confirmed, not assumed)
previewOnly          — snippet/preview only
metadataOnly          — title/author/cover/identifiers only
userProvidedText       — the user typed/pasted the text themselves (not yet built)
ocrCaptured              — captured via on-device Vision OCR of the user's own copy (not yet built)
unavailable               — nothing usable found
```

`userProvidedText` and `ocrCaptured` exist in the type today so the rest of the architecture
(quote search/autocomplete) can eventually treat them uniformly with provider-sourced text,
without another schema change — the OCR capture UI itself is future work, not part of this pass.
