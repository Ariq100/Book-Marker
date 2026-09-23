package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	liveUnreachable = rule("LIVE-UNREACHABLE", Medium, CatLive, "Deployment could not be reached",
		"Check the URL, DNS and firewall. Live checks for this target were skipped.")
	liveNoRedirect = rule("LIVE-HTTP-REDIRECT", High, CatLive, "Plain HTTP is served instead of redirecting to HTTPS",
		"Redirect every http:// request to https:// with a 301/308, then enable HSTS.")
	liveHSTS = rule("LIVE-HSTS", High, CatLive, "Strict-Transport-Security header missing",
		"Send `Strict-Transport-Security: max-age=31536000; includeSubDomains` so browsers never downgrade to HTTP.")
	liveHSTSShort = rule("LIVE-HSTS-SHORT", Low, CatLive, "HSTS max-age is shorter than 6 months",
		"Use max-age of at least 15552000 (180 days), ideally 31536000.")
	liveCSP = rule("LIVE-CSP", Medium, CatLive, "Content-Security-Policy header missing",
		"Add a CSP (start with `default-src 'self'` in report-only mode) to limit the damage of any XSS bug.")
	liveFrame = rule("LIVE-FRAMING", Medium, CatLive, "Page can be framed by other sites (clickjacking)",
		"Send `X-Frame-Options: DENY` or CSP `frame-ancestors 'none'`.")
	liveNoSniff = rule("LIVE-NOSNIFF", Low, CatLive, "X-Content-Type-Options: nosniff missing",
		"Send `X-Content-Type-Options: nosniff` so browsers do not guess content types.")
	liveReferrer = rule("LIVE-REFERRER", Low, CatLive, "Referrer-Policy missing",
		"Send `Referrer-Policy: strict-origin-when-cross-origin` so URLs with tokens do not leak to other sites.")
	liveServerHdr = rule("LIVE-VERSION-LEAK", Low, CatLive, "Server software version disclosed in headers",
		"Strip version numbers from Server / X-Powered-By headers.")
	liveOldTLS = rule("LIVE-OLD-TLS", High, CatLive, "Server accepts TLS 1.0 / 1.1",
		"Disable TLS 1.0 and 1.1; allow only TLS 1.2+.")
	liveCertSoon = rule("LIVE-CERT-EXPIRY", High, CatLive, "TLS certificate expires soon",
		"Renew now and automate renewal (ACME / managed certificates) with expiry alerts.")
	liveCertBad = rule("LIVE-CERT-INVALID", Critical, CatLive, "TLS certificate is invalid",
		"Install a certificate that is valid for this hostname and chains to a trusted root.")
	liveCORSReflect = rule("LIVE-CORS-REFLECT", Critical, CatLive, "CORS reflects arbitrary origins with credentials",
		"Only echo origins from an allow-list. Reflecting any origin with Allow-Credentials lets every website act as the logged-in user.")
	liveCORSAny = rule("LIVE-CORS-WILDCARD", Low, CatLive, "CORS allows any origin",
		"Fine for truly public, unauthenticated APIs; otherwise restrict to your own origins.")
	liveCookie = rule("LIVE-COOKIE-FLAGS", Medium, CatLive, "Cookie set without Secure / HttpOnly / SameSite",
		"Set Secure, HttpOnly and SameSite=Lax (or Strict) on session cookies.")
	liveExposed = rule("LIVE-EXPOSED-FILE", Critical, CatLive, "Sensitive file is publicly downloadable",
		"Block dotfiles and backups at the web server/CDN and remove them from the deploy artifact. Rotate anything they contained.")
	liveRateLimit = rule("LIVE-NO-RATE-LIMIT-HEADERS", Info, CatLive, "No rate-limit headers observed",
		"Not proof of a missing limit, but make sure an edge/WAF rate limit protects auth and expensive endpoints.")

	sbAnonRows = rule("LIVE-SB-ANON-READ", Critical, CatLive, "Supabase table returns rows to anonymous requests",
		"Enable RLS on the table and remove any policy that allows the anon role, or revoke select from anon.")
	sbAnonGrant = rule("LIVE-SB-ANON-GRANT", Low, CatLive, "Supabase table is readable by anon (0 rows returned)",
		"anon has SELECT privilege; RLS currently hides every row. If anon never needs this table, `revoke all on <table> from anon;` as defense in depth.")
	sbOpenAPI = rule("LIVE-SB-SCHEMA", Info, CatLive, "Anonymous callers can list the API schema",
		"Exposes table/function names. Consider disabling OpenAPI exposure for anon in the Data API settings.")
	sbAutoconfirm = rule("LIVE-SB-AUTOCONFIRM", High, CatLive, "Hosted Supabase project does not require email confirmation",
		"Dashboard → Authentication → Providers → Email → enable 'Confirm email'. Your local config.toml does not apply to the hosted project.")
	sbSignupOpen = rule("LIVE-SB-SIGNUP", Info, CatLive, "Public sign-ups are enabled",
		"Expected for consumer apps — make sure CAPTCHA and auth rate limits are on so bots cannot mass-create accounts.")
	sbFnOpen = rule("LIVE-SB-FUNCTION-OPEN", Medium, CatLive, "Edge Function runs for callers without a user session",
		"If it is not meant to be public, keep verify_jwt enabled / use auth: 'user'. Public functions need their own rate limiting.")
)

type liveTarget struct {
	URL, SupabaseURL, SupabaseKey string
	ProbeFunctions                bool
	Timeout                       time.Duration
}

func httpClient(timeout time.Duration, follow bool) *http.Client {
	c := &http.Client{Timeout: timeout}
	if !follow {
		c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	}
	return c
}

func get(c *http.Client, u string, hdr map[string]string) (*http.Response, []byte, error) {
	req, err := http.NewRequest("GET", u, nil)
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("User-Agent", "deploycheck/"+version)
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := c.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp, body, nil
}

func normalizeURL(raw string) (*url.URL, error) {
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return nil, fmt.Errorf("invalid URL %q", raw)
	}
	return u, nil
}

// runLive performs read-only checks against a deployed site. Nothing is written or modified.
func runLive(t liveTarget, p *Project) []Finding {
	var mu sync.Mutex
	var out []Finding
	add := func(fs ...Finding) {
		mu.Lock()
		out = append(out, fs...)
		mu.Unlock()
	}
	var wg sync.WaitGroup
	for _, raw := range strings.Split(t.URL, ",") {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		wg.Add(1)
		go func(raw string) { defer wg.Done(); add(checkSite(raw, t.Timeout)...) }(raw)
	}
	if t.SupabaseURL != "" && t.SupabaseKey != "" {
		wg.Add(1)
		go func() { defer wg.Done(); add(checkSupabase(t, p)...) }()
	}
	wg.Wait()
	return out
}

func checkSite(raw string, timeout time.Duration) []Finding {
	u, err := normalizeURL(raw)
	if err != nil {
		return []Finding{liveUnreachable.At(raw, 0, "").with(err.Error())}
	}
	target := u.String()
	var out []Finding
	at := func(m *RuleMeta, detail string) Finding { return m.At(target, 0, "").with(detail) }

	c := httpClient(timeout, true)
	resp, body, err := get(c, target, nil)
	if err != nil {
		if strings.Contains(err.Error(), "certificate") || strings.Contains(err.Error(), "x509") {
			return []Finding{at(liveCertBad, err.Error())}
		}
		return []Finding{at(liveUnreachable, err.Error())}
	}
	h := resp.Header
	isHTML := strings.Contains(h.Get("Content-Type"), "html") || strings.Contains(strings.ToLower(string(body[:min(len(body), 512)])), "<html")

	if u.Scheme == "https" {
		hsts := h.Get("Strict-Transport-Security")
		if hsts == "" {
			out = append(out, at(liveHSTS, ""))
		} else if m := regexp.MustCompile(`max-age=(\d+)`).FindStringSubmatch(hsts); m != nil {
			if n, _ := strconv.Atoi(m[1]); n < 15552000 {
				out = append(out, at(liveHSTSShort, hsts))
			}
		}
		// Plain HTTP must redirect to HTTPS.
		hu := *u
		hu.Scheme = "http"
		if r, _, err := get(httpClient(timeout, false), hu.String(), nil); err == nil {
			loc := r.Header.Get("Location")
			if r.StatusCode < 300 || r.StatusCode >= 400 || !strings.HasPrefix(loc, "https://") {
				out = append(out, at(liveNoRedirect, fmt.Sprintf("GET %s → %d %s", hu.String(), r.StatusCode, loc)))
			}
		}
		out = append(out, checkTLS(u, timeout, target)...)
	} else {
		out = append(out, at(liveNoRedirect, "target URL itself is http://"))
	}
	csp := h.Get("Content-Security-Policy")
	if isHTML && csp == "" {
		out = append(out, at(liveCSP, ""))
	}
	if isHTML && h.Get("X-Frame-Options") == "" && !strings.Contains(csp, "frame-ancestors") {
		out = append(out, at(liveFrame, ""))
	}
	if !strings.EqualFold(h.Get("X-Content-Type-Options"), "nosniff") {
		out = append(out, at(liveNoSniff, ""))
	}
	if isHTML && h.Get("Referrer-Policy") == "" {
		out = append(out, at(liveReferrer, ""))
	}
	for _, k := range []string{"Server", "X-Powered-By", "X-AspNet-Version", "X-AspNetMvc-Version"} {
		if v := h.Get(k); v != "" && regexp.MustCompile(`\d+\.\d+`).MatchString(v) {
			out = append(out, at(liveServerHdr, k+": "+v))
		}
	}
	for _, ck := range resp.Cookies() {
		if !ck.Secure || !ck.HttpOnly || ck.SameSite == http.SameSiteDefaultMode {
			var miss []string
			if !ck.Secure {
				miss = append(miss, "Secure")
			}
			if !ck.HttpOnly {
				miss = append(miss, "HttpOnly")
			}
			if ck.SameSite == http.SameSiteDefaultMode {
				miss = append(miss, "SameSite")
			}
			out = append(out, at(liveCookie, fmt.Sprintf("cookie %q missing %s", ck.Name, strings.Join(miss, ", "))))
		}
	}
	rl := false
	for k := range h {
		lk := strings.ToLower(k)
		if strings.Contains(lk, "ratelimit") || strings.Contains(lk, "rate-limit") || lk == "retry-after" {
			rl = true
		}
	}
	if !rl {
		out = append(out, at(liveRateLimit, ""))
	}

	// CORS: does the server echo an attacker-controlled origin?
	evil := "https://deploycheck-probe.invalid"
	if r, _, err := get(c, target, map[string]string{"Origin": evil}); err == nil {
		acao := r.Header.Get("Access-Control-Allow-Origin")
		creds := strings.EqualFold(r.Header.Get("Access-Control-Allow-Credentials"), "true")
		switch {
		case acao == evil && creds:
			out = append(out, at(liveCORSReflect, "Access-Control-Allow-Origin: "+acao))
		case acao == evil:
			out = append(out, at(liveCORSAny, "origin reflected without credentials"))
		case acao == "*":
			out = append(out, at(liveCORSAny, "Access-Control-Allow-Origin: *"))
		}
	}

	// Files that must never be publicly downloadable.
	probes := []struct{ path, signature string }{
		{"/.env", `(?m)^[A-Z_][A-Z0-9_]*=`},
		{"/.git/HEAD", `^ref: refs/`},
		{"/.git/config", `\[core\]`},
		{"/.DS_Store", "Bud1"},
		{"/backup.sql", `(?i)(create table|insert into)`},
		{"/dump.sql", `(?i)(create table|insert into)`},
		{"/.aws/credentials", `aws_access_key_id`},
		{"/config.json.bak", `\{`},
		{"/server-status", `Apache Server Status`},
		{"/phpinfo.php", `phpinfo\(\)|PHP Version`},
		{"/.vscode/settings.json", `^\s*\{`},
		{"/docker-compose.yml", `(?m)^services:`},
	}
	var pw sync.WaitGroup
	var pmu sync.Mutex
	nc := httpClient(timeout, false)
	for _, pr := range probes {
		pw.Add(1)
		go func(path, sig string) {
			defer pw.Done()
			pu := *u
			pu.Path = strings.TrimRight(u.Path, "/") + path
			r, b, err := get(nc, pu.String(), nil)
			if err != nil || r.StatusCode != 200 || strings.Contains(strings.ToLower(string(b[:min(len(b), 300)])), "<html") {
				return
			}
			if regexp.MustCompile(sig).Match(b) {
				pmu.Lock()
				out = append(out, at(liveExposed, pu.String()))
				pmu.Unlock()
			}
		}(pr.path, pr.signature)
	}
	pw.Wait()
	return out
}

func checkTLS(u *url.URL, timeout time.Duration, target string) []Finding {
	host := u.Hostname()
	port := u.Port()
	if port == "" {
		port = "443"
	}
	addr := net.JoinHostPort(host, port)
	var out []Finding
	d := &net.Dialer{Timeout: timeout}
	conn, err := tls.DialWithDialer(d, "tcp", addr, &tls.Config{ServerName: host})
	if err != nil {
		return []Finding{liveCertBad.At(target, 0, "").with(err.Error())}
	}
	state := conn.ConnectionState()
	conn.Close()
	if len(state.PeerCertificates) > 0 {
		left := time.Until(state.PeerCertificates[0].NotAfter)
		if left < 21*24*time.Hour {
			out = append(out, liveCertSoon.At(target, 0, "").with(fmt.Sprintf("expires %s (%d days)", state.PeerCertificates[0].NotAfter.Format("2006-01-02"), int(left.Hours()/24))))
		}
	}
	// Does the server still negotiate TLS 1.0/1.1?
	old, err := tls.DialWithDialer(d, "tcp", addr, &tls.Config{ServerName: host, MinVersion: tls.VersionTLS10, MaxVersion: tls.VersionTLS11})
	if err == nil {
		v := old.ConnectionState().Version
		old.Close()
		out = append(out, liveOldTLS.At(target, 0, "").with("negotiated "+tls.VersionName(v)))
	}
	return out
}

func checkSupabase(t liveTarget, p *Project) []Finding {
	base, err := normalizeURL(t.SupabaseURL)
	if err != nil {
		return []Finding{liveUnreachable.At(t.SupabaseURL, 0, "").with(err.Error())}
	}
	root := strings.TrimRight(base.String(), "/")
	hdr := map[string]string{"apikey": t.SupabaseKey}
	if strings.HasPrefix(t.SupabaseKey, "eyJ") {
		hdr["Authorization"] = "Bearer " + t.SupabaseKey // legacy anon JWT
	}
	if strings.HasPrefix(t.SupabaseKey, "sb_secret_") || jwtClaims(t.SupabaseKey)["role"] == "service_role" {
		return []Finding{liveUnreachable.At(root, 0, "").with("refusing to run: pass the public anon/publishable key, not a secret/service_role key — the point is to test what the public can reach")}
	}
	c := httpClient(t.Timeout, true)
	var out []Finding
	at := func(m *RuleMeta, detail string) Finding { return m.At(root, 0, "").with(detail) }

	// Table names: from the API's own schema listing (if anon may see it) plus the migrations.
	tables := map[string]bool{}
	if r, b, err := get(c, root+"/rest/v1/", mergeHdr(hdr, map[string]string{"Accept": "application/openapi+json"})); err == nil && r.StatusCode == 200 {
		var spec struct {
			Paths map[string]any `json:"paths"`
		}
		if json.Unmarshal(b, &spec) == nil && len(spec.Paths) > 1 {
			out = append(out, at(sbOpenAPI, fmt.Sprintf("%d paths listed", len(spec.Paths))))
			for pth := range spec.Paths {
				if pth != "/" && !strings.HasPrefix(pth, "/rpc/") {
					tables[strings.TrimPrefix(pth, "/")] = true
				}
			}
		}
	} else if err != nil {
		return []Finding{at(liveUnreachable, err.Error())}
	}
	for _, f := range p.filesWhere(exts(".sql")) {
		s, err := p.Read(f)
		if err != nil {
			continue
		}
		for _, m := range reCreateTable.FindAllStringSubmatch(stripSQLComments(s), -1) {
			if n := normIdent(m[1]); exposed(n) {
				tables[n] = true
			}
		}
	}
	var wg sync.WaitGroup
	var mu sync.Mutex
	sem := make(chan struct{}, 8) // bounded concurrency: be polite to the project
	for tbl := range tables {
		wg.Add(1)
		go func(tbl string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			r, b, err := get(c, root+"/rest/v1/"+url.PathEscape(tbl)+"?select=*&limit=1", hdr)
			if err != nil || r.StatusCode != 200 {
				return
			}
			body := strings.TrimSpace(string(b))
			mu.Lock()
			defer mu.Unlock()
			if strings.HasPrefix(body, "[{") {
				out = append(out, at(sbAnonRows, "table "+tbl))
			} else if body == "[]" {
				out = append(out, at(sbAnonGrant, "table "+tbl))
			}
		}(tbl)
	}
	wg.Wait()

	if r, b, err := get(c, root+"/auth/v1/settings", hdr); err == nil && r.StatusCode == 200 {
		var s struct {
			DisableSignup     bool `json:"disable_signup"`
			MailerAutoconfirm bool `json:"mailer_autoconfirm"`
		}
		if json.Unmarshal(b, &s) == nil {
			if s.MailerAutoconfirm {
				out = append(out, at(sbAutoconfirm, "mailer_autoconfirm: true"))
			}
			if !s.DisableSignup {
				out = append(out, at(sbSignupOpen, ""))
			}
		}
	}

	if t.ProbeFunctions {
		seen := map[string]bool{}
		for _, f := range p.Files {
			if !strings.HasPrefix(f, "supabase/functions/") {
				continue
			}
			parts := strings.Split(f, "/")
			if len(parts) < 4 || strings.HasPrefix(parts[2], "_") || seen[parts[2]] {
				continue
			}
			name := parts[2]
			seen[name] = true
			// OPTIONS-free POST with only the public apikey and an empty JSON body: a function that
			// requires a user session must answer 401/403 without doing any work.
			req, _ := http.NewRequest("POST", root+"/functions/v1/"+path.Clean(name), strings.NewReader("{}"))
			req.Header.Set("apikey", t.SupabaseKey)
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("User-Agent", "deploycheck/"+version)
			resp, err := c.Do(req)
			if err != nil {
				continue
			}
			resp.Body.Close()
			if resp.StatusCode != 401 && resp.StatusCode != 403 && resp.StatusCode != 404 {
				out = append(out, at(sbFnOpen, fmt.Sprintf("function %s answered %d without a user session", name, resp.StatusCode)))
			}
		}
	}
	return out
}

func mergeHdr(a, b map[string]string) map[string]string {
	m := map[string]string{}
	for k, v := range a {
		m[k] = v
	}
	for k, v := range b {
		m[k] = v
	}
	return m
}
