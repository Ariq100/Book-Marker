// supabase/functions/search-europeana/index.ts
//
// Proxies Europeana searches server-side so the private EUROPEANA_API_KEY (wskey) never ships
// inside the iOS app. Requires a signed-in Supabase user (auth: 'user'). Not a generic open
// proxy: only ever calls Europeana's fixed `record/v2/search.json` endpoint.
//
// Secret required: EUROPEANA_API_KEY (see SECRETS_SETUP.md for where to obtain and set it).
import { withSupabase } from 'npm:@supabase/server'

const EUROPEANA_API_KEY = Deno.env.get('EUROPEANA_API_KEY')
const MAX_QUERY_LENGTH = 200

interface EuropeanaItem {
  id: string
  title?: string[]
  dcCreator?: string[]
  dcPublisher?: string[]
  year?: string[]
  language?: string[]
  edmPreview?: string[]
  rights?: string[]
}

function normalize(item: EuropeanaItem) {
  const rightsStatement = item.rights?.[0] ?? null
  return {
    title: item.title?.[0] ?? 'Untitled',
    authors: item.dcCreator ?? [],
    publisher: item.dcPublisher?.[0] ?? null,
    publicationDate: item.year?.[0] ?? null,
    language: item.language?.[0] ?? null,
    coverImageURL: item.edmPreview?.[0] ?? null,
    providerID: item.id,
    // Europeana aggregates cultural-heritage metadata; treat as metadata/preview only unless the
    // rights statement explicitly marks it public domain — never assume full text.
    availability: rightsStatement?.toLowerCase().includes('public domain') ? 'previewOnly' : 'metadataOnly',
    rightsStatement,
  }
}

export default {
  fetch: withSupabase({ auth: 'user' }, async (req) => {
    if (!EUROPEANA_API_KEY) {
      return Response.json({ error: 'EUROPEANA_API_KEY is not configured on the server.' }, { status: 503 })
    }

    const url = new URL(req.url)
    const q = url.searchParams.get('q')

    if (!q || q.trim().length === 0) {
      return Response.json({ error: 'Missing required "q" query parameter.' }, { status: 400 })
    }
    if (q.length > MAX_QUERY_LENGTH) {
      return Response.json({ error: 'Query too long.' }, { status: 400 })
    }

    const europeanaURL = new URL('https://api.europeana.eu/record/v2/search.json')
    europeanaURL.searchParams.set('query', `TEXT AND ${q}`)
    europeanaURL.searchParams.set('qf', 'TYPE:TEXT')
    europeanaURL.searchParams.set('rows', '20')
    europeanaURL.searchParams.set('wskey', EUROPEANA_API_KEY)

    const europeanaResponse = await fetch(europeanaURL.toString())
    if (!europeanaResponse.ok) {
      // Never forward Europeana's raw response — avoid any chance of echoing the key back.
      return Response.json({ error: 'Upstream Europeana request failed.' }, { status: 502 })
    }

    const body = (await europeanaResponse.json()) as { items?: EuropeanaItem[] }
    const results = (body.items ?? []).map(normalize)
    return Response.json(results)
  }),
}
