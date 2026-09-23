// supabase/functions/delete-account/index.ts
//
// Deletes the CALLING user's own account and every piece of data stored for it. This is the one
// privileged operation the app needs: deleting an auth.users row requires the secret/service_role
// key, which must never be embedded client-side (see AuthManager.swift's deleteAccount()).
//
// The function only ever deletes `ctx.supabase.auth.getUser()`'s own id — it never accepts a
// user id from the request body, so there is no way for one user to delete another user's
// account by tampering with the request.
//
// What gets deleted:
//   * every row the user owns in USER_TABLES (books, quotes, vocab_words, quote_extractions)
//   * the auth.users row itself, which also removes their identities (email / Apple) and sessions
//
// The user-owned rows would also go via ON DELETE CASCADE on user_id (migrations 0001 and 0004),
// but they are deleted explicitly first so that a missing or dropped foreign key can never leave
// orphaned personal data behind. If any delete fails, the auth user is left intact and the
// function returns 500, so the app shows an error and the user can simply retry — a half-deleted
// account is never reported as success.
import { withSupabase } from 'npm:@supabase/server'

// Children before parents: quotes/vocab_words reference books via book_id.
const USER_TABLES = ['quotes', 'vocab_words', 'books', 'quote_extractions'] as const

export default {
  fetch: withSupabase({ auth: 'user' }, async (_req, ctx) => {
    const { data: userData, error: userError } = await ctx.supabase.auth.getUser()
    if (userError || !userData?.user) {
      return Response.json({ error: 'Not authenticated.' }, { status: 401 })
    }
    const userId = userData.user.id

    for (const table of USER_TABLES) {
      const { error } = await ctx.supabaseAdmin.from(table).delete().eq('user_id', userId)
      if (error) {
        console.error('delete-account: failed to delete rows', table, error.code)
        return Response.json({ error: 'Failed to delete account.' }, { status: 500 })
      }
    }

    // shouldSoftDelete defaults to false: the auth user is removed outright, not anonymised.
    const { error: deleteError } = await ctx.supabaseAdmin.auth.admin.deleteUser(userId)
    if (deleteError) {
      console.error('delete-account: failed to delete auth user', deleteError.status)
      return Response.json({ error: 'Failed to delete account.' }, { status: 500 })
    }

    return Response.json({ success: true })
  }),
}
