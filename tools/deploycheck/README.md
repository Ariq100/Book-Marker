# deploycheck

A single-file scanner that checks a project for the security and scalability problems that matter
before deploying to real users at scale. No install, no runtime, no network access unless you ask
for live checks.

## Run it

| Platform | Binary (in `dist/`) |
|---|---|
| Windows (most PCs) | `deploycheck-windows-x64.exe` |
| Windows on ARM | `deploycheck-windows-arm64.exe` |
| Mac (M1/M2/M3/M4) | `deploycheck-macos-apple-silicon` |
| Mac (Intel) | `deploycheck-macos-intel` |
| Linux | `deploycheck-linux-x64` / `deploycheck-linux-arm64` |

**Double-click** (Windows) or run it with no arguments: it asks which folder to scan (you can drag
the folder into the window), optionally a live URL and Supabase project, then prints the results
and saves `deploycheck-report.md` into the scanned folder.

**Command line / CI:**

```sh
deploycheck .                                      # scan the current folder
deploycheck --format sarif --out ds.sarif .        # GitHub code scanning
deploycheck --format json --fail-on medium .       # machine-readable, stricter gate
deploycheck --url https://myapp.com .              # + live HTTPS/header/CORS/exposed-file checks
deploycheck --supabase-url https://abc.supabase.co --supabase-key sb_publishable_... .
deploycheck --list-rules                           # every rule with its severity
```

Exit codes: `0` clean, `1` a finding at or above `--fail-on` (default `high`), `2` error.

On macOS, a downloaded binary may be quarantined: `xattr -d com.apple.quarantine deploycheck-macos-*`.
Windows SmartScreen may warn because the `.exe` is unsigned — choose "More info → Run anyway".

## What it checks

- **Secrets** — cloud/API keys, private keys, Supabase service_role/secret keys, JWTs, connection
  strings, hard-coded passwords, committed `.env`/key/state files, and **git history** (secrets
  deleted from the code but still in old commits). Secrets are always redacted in output.
- **Database & RLS** (Supabase/Postgres migrations) — tables without RLS, always-true policies,
  policies trusting `user_metadata`, SECURITY DEFINER without `search_path`, grants to `anon`,
  views that bypass RLS, missing primary keys, unindexed foreign keys and policy columns.
- **Auth & access** — CORS wildcards, weak hashing, insecure randomness, cookie flags, JWT
  verification bypasses, privileged keys in client code, debug mode, Supabase `config.toml` auth
  settings.
- **Injection** — SQL/shell/predicate injection, `eval`, XSS sinks, unsafe deserialization, SSRF.
- **Transport** — plain HTTP, disabled TLS verification, legacy TLS versions.
- **Mobile** — tokens in UserDefaults/SharedPreferences, ATS exceptions, Keychain accessibility,
  debug entitlements, Android manifest flags, missing privacy manifest.
- **Infrastructure** — Dockerfile, docker-compose, Kubernetes, Terraform, nginx, GitHub Actions.
- **Scalability** — outbound calls without timeouts, unpaginated queries (Supabase silently caps at
  1000 rows), N+1 loops, per-row `auth.uid()` in RLS, blocking I/O, missing probes/limits/autoscaling.
- **Supply chain** — unpinned imports and dependencies, missing lockfiles, no Dependabot/Renovate.
- **Live (opt-in, read-only)** — HTTPS redirect, HSTS/CSP/framing headers, TLS version and cert
  expiry, CORS origin reflection, publicly downloadable `.env`/`.git`, and for Supabase: tables that
  return rows to anonymous callers, hosted auth settings, Edge Functions reachable without a session
  (`--probe-functions`). Only the public anon/publishable key is accepted.

It also prints a **manual checklist** tailored to the detected stack (backups, WAF, SMTP limits,
App Attest, monitoring…) for things that cannot be verified from code.

## Suppressing findings

- On or above a line: `// deploycheck:ignore` (all rules) or `// deploycheck:ignore SEC015,SQL012`.
- In `.deploycheckignore` at the project root: a path glob (`generated/`), a rule ID (`SQL012`), or
  both (`SQL012 supabase/seed/*.sql`).

## Build from source

Requires Go 1.22+. `./build.sh` runs vet and tests, then cross-compiles every target into `dist/`
with SHA-256 checksums. Standard library only — no third-party dependencies.

## Limits

This is static analysis plus light live probing. It finds common, high-impact mistakes quickly; it
does not replace a penetration test, a dependency CVE scanner (`osv-scanner`, `npm audit`), or
Supabase's own Security/Performance Advisors against the live database.
