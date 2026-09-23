#!/usr/bin/env bash
#
# supabase_keepalive.sh — pings the Supabase project so it is never paused for inactivity.
#
# Supabase pauses free-tier projects after 7 days with no activity. Once paused, every sign-in,
# sync and Edge Function call from the app fails until the project is restored by hand in the
# dashboard. Running this every 3–4 days keeps the project awake with a wide safety margin.
#
# It calls the `public.keepalive()` RPC (migration 0006), which runs a real query in Postgres
# through the Data API — both the API and the database register activity — and touches no
# user data.
#
# Scheduled automatically by .github/workflows/supabase-keepalive.yml. To run it by hand:
#
#   SUPABASE_PROJECT_REF=<ref> SUPABASE_PUBLISHABLE_KEY=<key> scripts/supabase_keepalive.sh
#
# or, from a machine that has the app's gitignored Secrets.xcconfig, with no arguments at all.
#
# Configuration (environment variables):
#   SUPABASE_URL              Full project URL, e.g. https://abcd1234.supabase.co
#   SUPABASE_PROJECT_REF      Alternative to SUPABASE_URL: just the project ref
#   SUPABASE_PUBLISHABLE_KEY  The publishable (anon) key — the same one shipped in the app.
#                             NEVER use the secret/service_role key here.
#
# Exits 0 on success and non-zero on failure, so a scheduler can report the failure.

set -euo pipefail

readonly MAX_ATTEMPTS=4
readonly RETRY_DELAY_SECONDS=30

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
secrets_file="${script_dir}/../Secrets.xcconfig"

# Reads `KEY = value` from Secrets.xcconfig (xcconfig syntax, `//` comments).
read_xcconfig() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p" "$secrets_file" | head -n 1
}

url="${SUPABASE_URL:-}"
key="${SUPABASE_PUBLISHABLE_KEY:-}"
ref="${SUPABASE_PROJECT_REF:-}"

if [[ -f "$secrets_file" ]]; then
  [[ -z "$url" && -z "$ref" ]] && ref="$(read_xcconfig SUPABASE_PROJECT_REF)"
  [[ -z "$key" ]] && key="$(read_xcconfig SUPABASE_ANON_KEY)"
fi
[[ -z "$url" && -n "$ref" ]] && url="https://${ref}.supabase.co"
url="${url%/}"

if [[ -z "$url" || -z "$key" ]]; then
  echo "error: set SUPABASE_URL (or SUPABASE_PROJECT_REF) and SUPABASE_PUBLISHABLE_KEY." >&2
  exit 2
fi

# The secret key bypasses RLS entirely; refuse to send it anywhere it isn't needed.
if [[ "$key" == sb_secret_* ]]; then
  echo "error: SUPABASE_PUBLISHABLE_KEY is a secret key. Use the publishable key." >&2
  exit 2
fi

endpoint="${url}/rest/v1/rpc/keepalive"
response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  status="$(curl --silent --show-error --max-time 30 \
    --output "$response_file" --write-out '%{http_code}' \
    --request POST "$endpoint" \
    --header "apikey: ${key}" \
    --header "Content-Type: application/json" \
    --data '{}' || echo "000")"

  if [[ "$status" == "200" ]]; then
    echo "Supabase is awake (server time $(tr -d '"' < "$response_file"))."
    exit 0
  fi

  echo "Attempt ${attempt}/${MAX_ATTEMPTS} failed: HTTP ${status} $(head -c 300 "$response_file")" >&2
  if [[ "$status" == "404" ]]; then
    echo "hint: the keepalive() function is missing — run \`supabase db push\` to apply migration 0006." >&2
    exit 1
  fi
  # A paused or waking project answers 5xx/timeouts for a little while; retry before giving up.
  (( attempt < MAX_ATTEMPTS )) && sleep "$RETRY_DELAY_SECONDS"
done

echo "error: Supabase did not respond successfully after ${MAX_ATTEMPTS} attempts." >&2
echo "If the project has been paused, restore it from the Supabase dashboard." >&2
exit 1
