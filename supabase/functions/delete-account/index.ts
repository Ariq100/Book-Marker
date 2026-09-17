// supabase/functions/delete-account/index.ts
//
// Deletes the CALLING user's own account. This is the one privileged operation the app needs:
// deleting an auth.users row requires the secret/service_role key, which must never be embedded
// client-side (see AuthManager.swift's deleteAccount(), which already calls this function).
//
// The function only ever deletes `ctx.supabase.auth.getUser()`'s own id — it never accepts a
// user id from the request body, so there is no way for one user to delete another user's
// account by tampering with the request.
//
// Deleting the auth.users row cascades (ON DELETE CASCADE, migration 0001) to remove that
// user's books/quotes/vocab_words automatically.
import { withSupabase } from 'npm:@supabase/server'

export default {
  fetch: withSupabase({ auth: 'user' }, async (_req, ctx) => {
    const { data: userData, error: userError } = await ctx.supabase.auth.getUser()
    if (userError || !userData?.user) {
      return Response.json({ error: 'Not authenticated.' }, { status: 401 })
    }

    const { error: deleteError } = await ctx.supabaseAdmin.auth.admin.deleteUser(userData.user.id)
    if (deleteError) {
      return Response.json({ error: 'Failed to delete account.' }, { status: 500 })
    }

    return Response.json({ success: true })
  }),
}
