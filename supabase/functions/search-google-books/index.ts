// supabase/functions/search-google-books/index.ts
//
// Proxies Google Books searches server-side so the private GOOGLE_BOOKS_API_KEY never ships
// inside the iOS app. Requires a signed-in Supabase user (auth: 'user') — this is NOT a generic
// open proxy: it only ever calls Google's fixed `volumes` endpoint with a caller-supplied query
// string, never an arbitrary caller-supplied URL.
//
// Secret required: GOOGLE_BOOKS_API_KEY (see SECRETS_SETUP.md for where to obtain and set it).
import { withSupabase } from 'npm:@supabase/server'

const GOOGLE_BOOKS_API_KEY = Deno.env.get('GOOGLE_BOOKS_API_KEY')
const MAX_QUERY_LENGTH = 200

interface GoogleVolume {
  id: string
  volumeInfo?: {
    title?: string
    subtitle?: string
    authors?: string[]
    publisher?: string
    publishedDate?: string
    language?: string
    industryIdentifiers?: { type: string; identifier: string }[]
    imageLinks?: { thumbnail?: string; smallThumbnail?: string }
  }
  accessInfo?: {
    viewability?: string // "NO_PAGES" | "PARTIAL" | "ALL_PAGES" | "UNKNOWN"
    publicDomain?: boolean
    webReaderLink?: string
  }
}

function normalize(volume: GoogleVolume) {
  const info = volume.volumeInfo ?? {}
  const access = volume.accessInfo ?? {}
  const isbn13 = info.industryIdentifiers?.find((i) => i.type === 'ISBN_13')?.identifier
  const isbn10 = info.industryIdentifiers?.find((i) => i.type === 'ISBN_10')?.identifier

  const previewAvailable = access.viewability === 'PARTIAL' || access.viewability === 'ALL_PAGES'
  const fullTextAvailable = access.viewability === 'ALL_PAGES' && access.publicDomain === true

  return {
    title: info.title ?? 'Untitled',
    subtitle: info.subtitle ?? null,
    authors: info.authors ?? [],
    isbn10: isbn10 ?? null,
    isbn13: isbn13 ?? null,
    publisher: info.publisher ?? null,
    publicationDate: info.publishedDate ?? null,
    language: info.language ?? null,
    // Google serves cover thumbnails over http:// — upgrade to https for ATS.
    coverImageURL: (info.imageLinks?.thumbnail ?? info.imageLinks?.smallThumbnail ?? null)?.replace(/^http:/, 'https:') ?? null,
    providerID: volume.id,
    availability: fullTextAvailable ? 'fullTextAvailable' : previewAvailable ? 'previewOnly' : 'metadataOnly',
    fullTextAvailable,
    previewAvailable,
    textSource: previewAvailable ? access.webReaderLink ?? null : null,
    rightsStatement: access.publicDomain ? 'Public domain per Google Books' : null,
  }
}

export default {
  fetch: withSupabase({ auth: 'user' }, async (req) => {
    if (!GOOGLE_BOOKS_API_KEY) {
      return Response.json({ error: 'GOOGLE_BOOKS_API_KEY is not configured on the server.' }, { status: 503 })
    }

    const url = new URL(req.url)
    const q = url.searchParams.get('q')
    const isbn = url.searchParams.get('isbn')
    const rawQuery = isbn ? `isbn:${isbn}` : q

    if (!rawQuery || rawQuery.trim().length === 0) {
      return Response.json({ error: 'Missing required "q" or "isbn" query parameter.' }, { status: 400 })
    }
    if (rawQuery.length > MAX_QUERY_LENGTH) {
      return Response.json({ error: 'Query too long.' }, { status: 400 })
    }

    const googleURL = new URL('https://www.googleapis.com/books/v1/volumes')
    googleURL.searchParams.set('q', rawQuery)
    googleURL.searchParams.set('maxResults', '20')
    googleURL.searchParams.set('key', GOOGLE_BOOKS_API_KEY)

    const googleResponse = await fetch(googleURL.toString())
    if (!googleResponse.ok) {
      // Never forward Google's raw response — it could echo the API key back in error bodies.
      return Response.json({ error: 'Upstream Google Books request failed.' }, { status: 502 })
    }

    const body = (await googleResponse.json()) as { items?: GoogleVolume[] }
    const results = (body.items ?? []).map(normalize)
    return Response.json(results)
  }),
}
