package main

// CheckItem is something that cannot be verified from source code — it lives in dashboards, cloud
// consoles and processes — but still has to be true before an app is safe to run at scale.
type CheckItem struct {
	Area string `json:"area"`
	Item string `json:"item"`
	Why  string `json:"why"`
}

func checklistFor(p *Project) []CheckItem {
	items := []CheckItem{
		{"Secrets", "All production secrets live in a secret manager / platform secret store and have a documented rotation procedure.", "A leaked key you cannot rotate quickly turns an incident into an outage."},
		{"Secrets", "A pre-commit or CI secret scanner (e.g. this tool with --fail-on high, gitleaks, GitHub push protection) blocks new secrets.", "Prevention is far cheaper than rotation."},
		{"Access", "MFA is enforced on every account that can deploy or read production data (cloud, GitHub, DNS registrar, app stores, database dashboard).", "Account takeover of one maintainer is the most common path to a full breach."},
		{"Access", "Production access follows least privilege; ex-team-members and unused API keys are removed.", "Standing access is attack surface."},
		{"Edge", "A CDN/WAF with DDoS protection and rate limiting sits in front of public endpoints; auth, sign-up and password-reset endpoints have stricter limits.", "Bots target the cheapest expensive endpoint first."},
		{"Edge", "Bot protection (CAPTCHA/Turnstile/hCaptcha) guards sign-up, login and any endpoint that costs money per call.", "Automated account creation drains quotas and inflates bills."},
		{"Data", "Automated backups with point-in-time recovery are enabled, and a restore has actually been tested.", "Backups that were never restored are hopes, not backups."},
		{"Data", "Personal data is inventoried, encrypted at rest, and has a retention + deletion process (GDPR/CCPA account deletion).", "Required by law in most markets and by app store review."},
		{"Observability", "Centralized logs, error tracking and uptime/latency alerts exist, with PII and tokens scrubbed from logs.", "You cannot respond to an attack or outage you cannot see."},
		{"Observability", "Security-relevant events (logins, failed logins, permission changes, key usage) are logged and alert on anomalies.", "Detection time drives breach cost."},
		{"Resilience", "Load testing has been done at 2–3× expected peak; you know which component fails first.", "The first real traffic spike should not be the load test."},
		{"Resilience", "Every dependency call has a timeout, retries use exponential backoff with jitter, and there is a circuit breaker/graceful degradation for third-party APIs.", "Retry storms turn a slow dependency into a full outage."},
		{"Resilience", "Budgets and spend alerts are configured for every metered service (cloud, AI APIs, email/SMS).", "Abuse at scale often shows up first as a bill."},
		{"Process", "Dependencies are scanned for known CVEs in CI (npm audit / pip-audit / osv-scanner / Dependabot alerts).", "Most exploited vulnerabilities are in dependencies, not your code."},
		{"Process", "A written incident-response plan exists: who is paged, how to rotate keys, how to notify users.", "Minutes matter; improvising costs hours."},
		{"Process", "Separate staging and production environments with separate credentials and data.", "Testing against production data leaks it; sharing keys means one breach is two."},
		{"Process", "A SECURITY.md / security contact exists for responsible disclosure.", "Researchers who cannot reach you publish instead."},
	}
	if p.Stack["supabase"] {
		items = append(items,
			CheckItem{"Supabase", "Run Dashboard → Advisors → Security Advisor and Performance Advisor; resolve every error and warning.", "Catches RLS gaps, exposed functions and missing indexes in the live database, not just migrations."},
			CheckItem{"Supabase", "Point-in-Time Recovery is enabled for the production project (Pro plan and above).", "Daily backups alone can lose up to 24h of user data."},
			CheckItem{"Supabase", "Custom SMTP is configured for Auth emails.", "The built-in email service is heavily rate-limited — at scale, sign-up and password-reset emails silently stop being delivered."},
			CheckItem{"Supabase", "Auth → Rate Limits are reviewed, CAPTCHA protection is enabled, and leaked-password protection (HaveIBeenPwned) is on.", "Defaults are tuned for development, not public launch."},
			CheckItem{"Supabase", "Hosted Auth settings match supabase/config.toml (email confirmation, password policy, redirect URLs, providers).", "config.toml only applies to the local stack; the hosted project keeps its own settings."},
			CheckItem{"Supabase", "SSL enforcement and Network Restrictions are enabled for direct database connections.", "Blocks plaintext and unexpected-origin connections to Postgres."},
			CheckItem{"Supabase", "Server-side and serverless code connects through the connection pooler (Supavisor, transaction mode); compute size matches the max connection count you need.", "Serverless bursts exhaust direct Postgres connections long before CPU is the limit."},
			CheckItem{"Supabase", "The Data API max_rows limit and statement_timeout for anon/authenticated roles are set deliberately.", "Prevents a single request from scanning or returning an entire table."},
			CheckItem{"Supabase", "Legacy JWT anon/service_role keys are migrated to publishable/secret API keys, and the JWT secret has never been shared.", "New keys can be rotated individually without logging every user out."},
			CheckItem{"Supabase", "Storage buckets are private unless intentionally public, with RLS policies on storage.objects and file size/MIME limits.", "Public buckets are a common data-leak source."},
			CheckItem{"Supabase", "Spend cap / usage alerts are configured, and Edge Function secrets (e.g. third-party API keys) have per-key quotas at the provider.", "A leaked or abused function key is billed to you."},
		)
	}
	if p.Stack["ios"] || p.Stack["android"] {
		items = append(items,
			CheckItem{"Mobile", "Enable App Attest / DeviceCheck (iOS) or Play Integrity (Android) and verify it server-side for expensive or abusable endpoints.", "The public API key in the app binary is extractable; attestation proves requests come from your genuine app."},
			CheckItem{"Mobile", "Release builds strip debug logging and are built with the Release configuration (no get-task-allow, no debug menus).", "Debug output in production leaks tokens and internals to device logs."},
			CheckItem{"Mobile", "Data files written by the app use Data Protection (NSFileProtectionComplete or ...UntilFirstUserAuthentication).", "Protects local data if the device is lost."},
			CheckItem{"Mobile", "Sensitive screens are hidden from the app switcher snapshot, and the pasteboard is not used for secrets.", "Snapshots and clipboard contents leak to other apps and backups."},
			CheckItem{"Mobile", "A forced-update / minimum-version mechanism exists.", "Lets you retire app versions with a vulnerability or an old API contract."},
		)
	}
	if p.Stack["node"] || p.Stack["python"] || p.Stack["go"] || p.Stack["docker"] {
		items = append(items,
			CheckItem{"Web", "Request body size limits, request timeouts and pagination caps are enforced on every endpoint.", "Unbounded input is the easiest denial of service."},
			CheckItem{"Web", "Security headers (HSTS, CSP, X-Content-Type-Options, frame-ancestors) are set — verify with `deploycheck --url https://your.site`.", "Browser-side defense in depth."},
			CheckItem{"Web", "The app is stateless (sessions/files in shared stores) so any instance can serve any request.", "Required for horizontal scaling and zero-downtime deploys."},
		)
	}
	if p.Stack["kubernetes"] || p.Stack["terraform"] || p.Stack["docker"] {
		items = append(items,
			CheckItem{"Infrastructure", "Container images are scanned (Trivy/Grype) in CI and rebuilt regularly for base-image patches.", "Base images accumulate CVEs even when your code does not change."},
			CheckItem{"Infrastructure", "Infrastructure is deployed across at least two availability zones with health-checked load balancing.", "A single zone is a single point of failure."},
		)
	}
	return items
}
