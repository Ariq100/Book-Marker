// supabase/functions/extract-quote/index.ts
//
// Turns a photo of a book page, on which the user has painted a translucent yellow highlight,
// into the text of that highlighted passage using Gemini. Called by QuoteExtractionService.swift.
//
// Why server-side: the Gemini API key is billed to the project and would be trivially extracted
// from an app binary. It lives only in this function's secrets.
//
// Abuse controls:
//   * auth: 'user' — only signed-in users; the user id comes from the verified JWT, never the body.
//   * Per-user hourly and daily caps, recorded in public.quote_extractions (migration 0004).
//   * Request size and MIME type are validated before anything is forwarded to Google.
//   * Google's raw error bodies are never forwarded to the client.
//
// Secrets required: GEMINI_API_KEY. Optional: GEMINI_MODEL (defaults to DEFAULT_MODEL below).
import { withSupabase } from 'npm:@supabase/server'

const GEMINI_API_KEY = Deno.env.get('GEMINI_API_KEY')
const DEFAULT_MODEL = 'gemini-2.5-flash'
const GEMINI_MODEL = Deno.env.get('GEMINI_MODEL') || DEFAULT_MODEL

const MAX_IMAGE_BASE64_LENGTH = 6_000_000 // ~4.5 MB decoded; the app sends ~1600px JPEGs well under this
const ALLOWED_MIME_TYPES = new Set(['image/jpeg', 'image/png'])
const MAX_QUOTE_LENGTH = 2000
const HOURLY_LIMIT = 30
const DAILY_LIMIT = 150

const PROMPT = `This is a photo of a page from a book. The reader has marked one passage by painting over it with a translucent yellow highlighter.

Transcribe ONLY the text that lies under the yellow highlight, exactly as printed.
- Join words hyphenated across a line break, and join lines into normal flowing sentences.
- Do not add quotation marks, commentary, page numbers, headers, or any text that is not highlighted.
- If a highlight partially covers a word at the start or end, include the whole word.
- If there is no yellow highlight, or the highlighted text is unreadable, set "found" to false and "quote" to "".`

function error(status: number, code: string, message: string) {
  return Response.json({ error: message, code }, { status })
}

export default {
  fetch: withSupabase({ auth: 'user' }, async (req, ctx) => {
    if (req.method !== 'POST') return error(405, 'method_not_allowed', 'Use POST.')
    if (!GEMINI_API_KEY) return error(503, 'not_configured', 'Quote extraction is not configured on the server.')

    const { data: userData, error: userError } = await ctx.supabase.auth.getUser()
    if (userError || !userData?.user) return error(401, 'not_authenticated', 'Not authenticated.')
    const userId = userData.user.id

    // ---- Validate input ----
    const contentLength = Number(req.headers.get('content-length') ?? '0')
    if (contentLength > MAX_IMAGE_BASE64_LENGTH + 1024) return error(413, 'too_large', 'Image too large.')

    let body: { image?: unknown; mimeType?: unknown }
    try {
      body = await req.json()
    } catch {
      return error(400, 'bad_request', 'Body must be JSON.')
    }
    const image = body.image
    const mimeType = body.mimeType
    if (typeof image !== 'string' || image.length === 0) return error(400, 'bad_request', 'Missing image.')
    if (image.length > MAX_IMAGE_BASE64_LENGTH) return error(413, 'too_large', 'Image too large.')
    if (typeof mimeType !== 'string' || !ALLOWED_MIME_TYPES.has(mimeType)) {
      return error(400, 'bad_request', 'Unsupported image type.')
    }
    if (!/^[A-Za-z0-9+/]+={0,2}$/.test(image)) return error(400, 'bad_request', 'Image must be base64.')

    // ---- Rate limit ----
    const now = Date.now()
    const dayAgo = new Date(now - 24 * 60 * 60 * 1000).toISOString()
    const hourAgo = new Date(now - 60 * 60 * 1000).toISOString()
    const { data: recent, error: countError } = await ctx.supabaseAdmin
      .from('quote_extractions')
      .select('created_at')
      .eq('user_id', userId)
      .gte('created_at', dayAgo)
      .limit(DAILY_LIMIT)
    if (countError) return error(500, 'server_error', 'Could not check usage.')
    const dailyCount = recent?.length ?? 0
    const hourlyCount = recent?.filter((r) => r.created_at >= hourAgo).length ?? 0
    if (dailyCount >= DAILY_LIMIT || hourlyCount >= HOURLY_LIMIT) {
      return error(429, 'rate_limited', 'Too many extractions. Please try again later.')
    }

    // Record the attempt before calling Gemini so concurrent requests can't all slip under the cap.
    const { error: insertError } = await ctx.supabaseAdmin.from('quote_extractions').insert({ user_id: userId })
    if (insertError) return error(500, 'server_error', 'Could not record usage.')

    // ---- Call Gemini ----
    const geminiURL = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(GEMINI_MODEL)}:generateContent`
    const geminiResponse = await fetch(geminiURL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': GEMINI_API_KEY },
      body: JSON.stringify({
        contents: [{ parts: [{ inline_data: { mime_type: mimeType, data: image } }, { text: PROMPT }] }],
        generationConfig: {
          temperature: 0,
          responseMimeType: 'application/json',
          responseSchema: {
            type: 'OBJECT',
            properties: { found: { type: 'BOOLEAN' }, quote: { type: 'STRING' } },
            required: ['found', 'quote'],
          },
        },
      }),
    })
    if (!geminiResponse.ok) {
      console.error('Gemini request failed', geminiResponse.status)
      return error(502, 'upstream_error', 'Could not read the photo right now.')
    }

    let found = false
    let quote = ''
    try {
      const result = await geminiResponse.json()
      const text: string = result?.candidates?.[0]?.content?.parts?.[0]?.text ?? ''
      const parsed = JSON.parse(text)
      found = parsed?.found === true
      quote = typeof parsed?.quote === 'string' ? parsed.quote.trim() : ''
    } catch {
      return error(502, 'upstream_error', 'Could not read the photo right now.')
    }

    if (!found || quote.length === 0) {
      return error(422, 'no_highlight', 'No highlighted text was found.')
    }
    return Response.json({ quote: quote.slice(0, MAX_QUOTE_LENGTH) })
  }),
}
