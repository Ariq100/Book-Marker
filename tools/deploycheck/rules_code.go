package main

import (
	"regexp"
	"strconv"
	"strings"
)

var (
	trnHTTP = rule("TRN001", Medium, CatTransport, "Plain-HTTP URL in application code",
		"Use https://. Plain HTTP can be read and modified by anyone on the network path (public Wi-Fi, ISPs, proxies).")
	trnTLSOff = rule("TRN002", High, CatTransport, "TLS certificate verification disabled",
		"Remove the override. Disabling verification makes HTTPS trivially interceptable (man-in-the-middle).")
	trnWeakTLS = rule("TRN003", High, CatTransport, "Legacy TLS/SSL protocol enabled",
		"Allow only TLS 1.2 and 1.3.")

	injEval = rule("INJ001", High, CatInjection, "Dynamic code execution (eval / new Function)",
		"Never evaluate strings as code. Parse data with JSON.parse or a real parser instead.")
	injSQL = rule("INJ002", High, CatInjection, "SQL built with string interpolation or concatenation",
		"Use parameterized queries / prepared statements (`$1`, `?`, or a query builder). Interpolated SQL is injectable.")
	injPredicate = rule("INJ003", Medium, CatInjection, "NSPredicate built with string interpolation",
		"Use format arguments: `NSPredicate(format: \"name == %@\", value)` — interpolation allows predicate injection.")
	injXSS = rule("INJ004", Medium, CatInjection, "Raw HTML injection sink (possible XSS)",
		"Render text through the framework's escaping, or sanitize with a vetted library (e.g. DOMPurify) before inserting HTML.")
	injShell = rule("INJ005", High, CatInjection, "Shell command built from interpolated input",
		"Pass arguments as an array (execFile / subprocess.run([...]) with shell=False) instead of building a shell string.")
	injDeserialize = rule("INJ006", Medium, CatInjection, "Unsafe deserialization",
		"pickle/marshal/yaml.load on untrusted input allows remote code execution. Use JSON or yaml.safe_load.")
	injSSRF = rule("INJ007", Medium, CatInjection, "Server fetches a URL taken directly from the request",
		"Validate against an allow-list of hosts and block private/link-local ranges (169.254.169.254, 10.0.0.0/8 ...) to prevent SSRF.")

	authJWTNone = rule("AUTH001", High, CatAuth, "JWT verification weakened or disabled",
		"Always verify the signature with an explicit algorithm allow-list and keep expiry checks on.")
	authWeakHash = rule("AUTH002", Medium, CatAuth, "Weak hash algorithm (MD5 / SHA-1)",
		"Use bcrypt/scrypt/Argon2 for passwords and SHA-256 or better for integrity checks.")
	authRandom = rule("AUTH003", Medium, CatAuth, "Non-cryptographic randomness used for a security value",
		"Use crypto.randomUUID()/crypto.getRandomValues() (JS), secrets (Python), SecRandomCopyBytes (Swift).")
	authCookie = rule("AUTH004", Medium, CatAuth, "Cookie or session hardening flag turned off",
		"Session cookies need Secure, HttpOnly and SameSite=Lax/Strict.")
	authCORS = rule("AUTH005", Medium, CatAuth, "CORS allows every origin",
		"Allow only your own front-end origins. A wildcard combined with credentials lets any website make authenticated calls.")
	authClientSecret = rule("AUTH006", Critical, CatAuth, "Privileged Supabase key referenced in client-side code",
		"service_role / secret keys bypass RLS. They must only exist server-side (Edge Functions, backend). Use the publishable/anon key in apps.")
	authDebug = rule("AUTH007", High, CatAuth, "Debug mode or wildcard host enabled in server configuration",
		"Disable debug in production; it leaks stack traces, settings and sometimes an interactive console.")
	authEdgeNoAuth = rule("AUTH008", Medium, CatAuth, "Edge Function accepts unauthenticated callers",
		"Confirm this endpoint is meant to be public and that it is rate-limited and cannot trigger paid/privileged work.")

	logSensitive = rule("LOG001", Medium, CatLogging, "Possible secret or personal data written to logs",
		"Never log passwords, tokens, cookies or full auth headers. Logs are widely readable and retained for a long time.")
	logLeak = rule("LOG002", Medium, CatLogging, "Internal error details returned to the client",
		"Log the error server-side and return a generic message with a correlation id. Stack traces and driver errors reveal internals.")

	mobDefaults = rule("MOB001", High, CatMobile, "Credential stored in plain-text app storage",
		"UserDefaults / SharedPreferences / localStorage are unencrypted and included in backups. Use the Keychain (iOS), EncryptedSharedPreferences/Keystore (Android) or HttpOnly cookies (web).")
	mobAccessible = rule("MOB002", High, CatMobile, "Keychain item readable while the device is locked",
		"Use kSecAttrAccessibleWhenUnlocked(ThisDeviceOnly) or AfterFirstUnlockThisDeviceOnly.")
	mobATS = rule("MOB003", High, CatMobile, "App Transport Security disabled for all connections",
		"Remove NSAllowsArbitraryLoads. If one legacy host needs HTTP, add a narrow NSExceptionDomains entry instead.")
	mobATSException = rule("MOB004", Medium, CatMobile, "App Transport Security exception allows insecure HTTP",
		"Move the server to HTTPS and remove the exception.")
	mobGetTask = rule("MOB005", High, CatMobile, "Debug entitlement (get-task-allow) enabled",
		"Release builds must not allow debuggers to attach. Let Xcode manage this entitlement per configuration.")
	mobPrivacy = rule("MOB006", Medium, CatMobile, "iOS privacy manifest (PrivacyInfo.xcprivacy) missing",
		"App Store Connect requires a privacy manifest declaring required-reason APIs and collected data.")
	mobAndroid = rule("MOB007", High, CatMobile, "Insecure Android manifest setting",
		"Set android:debuggable=false, android:usesCleartextTraffic=false and android:allowBackup=false (or define backup rules).")

	cfgVerifyJWT = rule("CFG001", Medium, CatAuth, "Supabase Edge Function has JWT verification turned off",
		"Only disable verify_jwt for webhooks that verify their own signature. Otherwise anyone on the internet can invoke the function.")
	cfgConfirm = rule("CFG002", High, CatAuth, "Supabase email confirmation disabled",
		"Enable [auth.email] enable_confirmations — otherwise anyone can register with someone else's address. Mirror the setting in the hosted dashboard.")
	cfgPwLen = rule("CFG003", Medium, CatAuth, "Weak minimum password length",
		"Set minimum_password_length to at least 8 (10+ recommended) and enable leaked-password protection in the dashboard.")
	cfgJWTExp = rule("CFG005", Low, CatAuth, "Long-lived access tokens",
		"Keep jwt_expiry at 3600s or less; refresh tokens handle longer sessions and stolen access tokens expire sooner.")
	cfgAnon = rule("CFG006", Medium, CatAuth, "Anonymous sign-ins enabled",
		"Anonymous users get the `authenticated` role. Make sure RLS policies check `is_anonymous` where needed and enable CAPTCHA to prevent mass account creation.")
	cfgSiteURL = rule("CFG008", Medium, CatAuth, "Auth site_url / redirect URL uses plain HTTP",
		"Use HTTPS for every non-localhost redirect URL so tokens in the redirect cannot be intercepted.")
	cfgRefreshRot = rule("CFG012", Medium, CatAuth, "Refresh token rotation disabled",
		"Enable enable_refresh_token_rotation so a stolen refresh token can be detected and revoked.")
	cfgSecurePw = rule("CFG013", Low, CatAuth, "Password change does not require recent login",
		"Set secure_password_change = true so a stolen session cannot silently change the password.")

	sclFetchTimeout = rule("SCL001", Medium, CatScale, "Outbound HTTP call without a timeout",
		"Pass `signal: AbortSignal.timeout(10_000)` (or your client's timeout option). A slow upstream otherwise holds connections, memory and function wall-time until the platform kills it — under load this cascades into outages.")
	sclUnbounded = rule("SCL002", Medium, CatScale, "Query reads a whole table without a limit / pagination",
		"Paginate with .range()/.limit() or keyset pagination. Supabase's API also caps responses at max_rows (1000 by default), so unpaginated reads silently return partial data once a user has more rows.")
	sclNPlusOne = rule("SCL003", Low, CatScale, "Database or network call inside a loop (N+1 pattern)",
		"Batch the work: one query with `in (...)`, a bulk upsert, or Promise.all with bounded concurrency.")
	sclSyncIO = rule("SCL004", Low, CatScale, "Blocking synchronous I/O in server code",
		"Use the async variant. Synchronous I/O blocks the event loop and stalls every concurrent request.")
	sclUnpinnedImport = rule("SUP004", Medium, CatSupply, "Remote/npm import without a pinned version",
		"Pin an exact version (e.g. `npm:@supabase/server@1.2.3`, `https://deno.land/x/lib@1.2.3/mod.ts`). Unpinned imports can change — or be hijacked — between deploys and cold starts.")
)

var sensitiveWords = []string{"password", "passwd", "secret", "token", "authorization", "api_key", "apikey",
	"cookie", "credential", "private_key", "ssn", "card_number", "cvv", "bearer"}

var httpURL = regexp.MustCompile(`http://[^\s"'<>)\]]+`)
var httpAllowed = regexp.MustCompile(`(?i)http://(?:localhost|127\.|0\.0\.0\.0|10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.|\[::1\]|[^/]*\.local\b|[^/]*\.test\b|[^/]*\.internal\b|host\.docker\.internal|(?:www\.)?example\.(?:com|org|net)|schemas\.|www\.w3\.org|www\.apple\.com/DTDs|json-schema\.org|xmlns|ns\.adobe\.com|purl\.org|[^/]*\.xsd)`)

func init() {
	lineRules = append(lineRules,
		&LineRule{Meta: trnHTTP, Files: either(codeMatcher, exts(".plist", ".xcconfig")), SkipComments: true, Keywords: []string{"http://"},
			Pattern: httpURL,
			Check: func(m string, _ []string, _ string) *RuleMeta {
				if httpAllowed.MatchString(m) {
					return nil
				}
				return trnHTTP
			}},
		&LineRule{Meta: trnTLSOff, Files: either(codeOrConfig, exts(".sh", ".yml", ".yaml")), SkipComments: true,
			Keywords: []string{"rejectunauthorized", "node_tls_reject_unauthorized", "verify", "insecureskipverify", "ssl_verifypeer", "insecure", "curl", "urlcredential(trust", "servercertificatevalidationcallback", "trustmanager", "hostnameverifier"},
			Pattern:  regexp.MustCompile(`rejectUnauthorized\s*:\s*false|NODE_TLS_REJECT_UNAUTHORIZED\s*=\s*['"]?0|\bverify\s*=\s*False|InsecureSkipVerify\s*:\s*true|CURLOPT_SSL_VERIFYPEER\s*,\s*(?:false|0)|\bcurl\b[^\n]*\s(?:-k|--insecure)\b|URLCredential\(trust:|ServerCertificateValidationCallback\s*=|X509TrustManager|ALLOW_ALL_HOSTNAME_VERIFIER|HostnameVerifier\s*\{\s*_,\s*_\s*->\s*true`)},
		&LineRule{Meta: trnWeakTLS, Files: codeOrConfig, SkipComments: true, Keywords: []string{"ssl", "tls"},
			Pattern: regexp.MustCompile(`(?i)ssl_protocols[^;\n]*\b(?:SSLv2|SSLv3|TLSv1(?:\.1)?)(?:\s|;|$)|minVersion\s*[:=]\s*['"]?TLSv1(?:\.1)?['"]?|MinVersion\s*:\s*tls\.VersionTLS1[01]\b|TLSMinimumSupportedProtocol[^\n]*TLSv1[01]?\b|ssl\.PROTOCOL_(?:TLSv1|SSLv[23])\b`)},

		&LineRule{Meta: injEval, Files: exts(append(jsExts, ".py", ".rb", ".php")...), SkipComments: true, Keywords: []string{"eval", "function("},
			Pattern: regexp.MustCompile(`\beval\s*\(|\bnew\s+Function\s*\(|\bsetTimeout\s*\(\s*['"]`)},
		&LineRule{Meta: injSQL, Files: codeMatcher, SkipComments: true, Keywords: []string{"select", "insert", "update", "delete", "query", "execute", "exec", "raw", "sqlite3_"},
			Pattern: regexp.MustCompile("(?i)(?:\\b(?:query|execute|exec|raw|unsafe|queryRaw|executeRaw|\\$queryRawUnsafe|\\$executeRawUnsafe)\\s*\\(\\s*`[^`]*\\$\\{|\\.execute\\(\\s*(?:f[\"']|[\"'][^\"']*[\"']\\s*(?:%|\\.format\\(|\\+))|sqlite3_(?:exec|prepare(?:_v[23])?)\\([^,]+,\\s*\"[^\"]*\\\\\\(|[\"'`](?:select\\s[^\"'`]*\\sfrom|insert\\s+into|update\\s+\\w+\\s+set|delete\\s+from)\\s[^\"'`]*[\"'`]\\s*\\+\\s*[a-z_])")},
		&LineRule{Meta: injPredicate, Files: exts(".swift"), Keywords: []string{"nspredicate"},
			Pattern: regexp.MustCompile(`NSPredicate\(format:\s*"[^"]*\\\(`)},
		&LineRule{Meta: injXSS, Files: exts(append(jsExts, ".html", ".py", ".rb", ".erb", ".php")...), SkipComments: true,
			Keywords: []string{"dangerouslysetinnerhtml", "innerhtml", "document.write", "v-html", "safe", "html_safe", "{@html", "bypasssecuritytrust"},
			Pattern:  regexp.MustCompile(`dangerouslySetInnerHTML|\.(?:inner|outer)HTML\s*\+?=|document\.write\s*\(|v-html=|\|\s*safe\b|mark_safe\(|\.html_safe\b|\{@html\s|bypassSecurityTrust\w+\(`)},
		&LineRule{Meta: injShell, Files: exts(append(serverExts, ".jsx", ".tsx")...), SkipComments: true, Keywords: []string{"exec", "shell=true", "os.system", "popen", "runtime.getruntime"},
			Pattern: regexp.MustCompile("\\bexec(?:Sync)?\\s*\\(\\s*`[^`]*\\$\\{|\\bexec(?:Sync)?\\s*\\([^)]*\\+\\s*\\w|shell\\s*=\\s*True|\\bos\\.(?:system|popen)\\s*\\(|Runtime\\.getRuntime\\(\\)\\.exec\\(")},
		&LineRule{Meta: injDeserialize, Files: exts(".py", ".rb", ".php", ".java"), SkipComments: true, Keywords: []string{"pickle", "marshal", "yaml.load", "unserialize", "objectinputstream"},
			Pattern: regexp.MustCompile(`\bpickle\.loads?\(|\bmarshal\.loads\(|\byaml\.load\(|\bYAML\.load\(|\bunserialize\(|new\s+ObjectInputStream\(`),
			Exclude: regexp.MustCompile(`SafeLoader|safe_load|CSafeLoader`)},
		&LineRule{Meta: injSSRF, Files: exts(serverExts...), SkipComments: true, Keywords: []string{"fetch", "axios", "requests.", "http.get", "urlopen"},
			Pattern: regexp.MustCompile(`(?:\bfetch|axios(?:\.\w+)?|requests\.(?:get|post)|http\.Get|urlopen)\s*\(\s*(?:req|request|ctx\.request|event|body|params|query)\.(?:body|query|params|url|json)?\.?\w*`)},

		&LineRule{Meta: authJWTNone, Files: codeMatcher, SkipComments: true, Keywords: []string{"none", "verify", "ignoreexpiration", "jwt.decode"},
			Pattern: regexp.MustCompile(`(?i)algorithms?\s*[:=]\s*\[?\s*['"]none['"]|verify_signature['"]?\s*:\s*False|jwt\.decode\([^)]*verify\s*=\s*False|ignoreExpiration\s*:\s*true|\bjwt\.decode\(`),
			Exclude: regexp.MustCompile(`jwt\.decode\([^)]*(?:key|secret|algorithms)`)},
		&LineRule{Meta: authWeakHash, Files: codeMatcher, SkipComments: true, Keywords: []string{"md5", "sha1"},
			Pattern: regexp.MustCompile(`createHash\(\s*['"](?:md5|sha1)['"]|hashlib\.(?:md5|sha1)\(|\bInsecure\.(?:MD5|SHA1)\b|\bCC_(?:MD5|SHA1)\(|MessageDigest\.getInstance\(\s*"(?:MD5|SHA-?1)"|\bmd5\s*\(\s*\$?pass`),
			Exclude: regexp.MustCompile(`(?i)usedforsecurity\s*=\s*False|etag|checksum|cache`)},
		&LineRule{Meta: authRandom, Files: codeMatcher, SkipComments: true, Keywords: []string{"math.random", "random."},
			Pattern: regexp.MustCompile(`Math\.random\(\)|\brandom\.(?:random|randint|choice|choices|getrandbits)\(`),
			Check: func(_ string, _ []string, line string) *RuleMeta {
				if containsAny(strings.ToLower(line), []string{"token", "secret", "password", "nonce", "otp", "session", "salt", "apikey", "api_key", "verification", "reset", "invite"}) {
					return authRandom
				}
				return nil
			}},
		&LineRule{Meta: authCookie, Files: exts(serverExts...), SkipComments: true, Keywords: []string{"httponly", "http_only", "secure", "samesite"},
			Pattern: regexp.MustCompile(`(?i)\bhttp_?only\s*[:=]\s*false|\bsecure\s*[:=]\s*false|samesite\s*[:=]\s*['"]?none|SESSION_COOKIE_SECURE\s*=\s*False|CSRF_COOKIE_SECURE\s*=\s*False`)},
		&LineRule{Meta: authCORS, Files: either(codeMatcher, exts(".json", ".yml", ".yaml", ".toml", ".conf")), SkipComments: true,
			Keywords: []string{"access-control-allow-origin", "cors", "origin", "allowanyorigin", "allow_origins"},
			Pattern:  regexp.MustCompile(`(?i)access-control-allow-origin['"]?\s*[:,=]\s*['"]\*['"]|\bcors\(\s*\)|\borigins?\s*:\s*(?:['"]\*['"]|true\b)|CORS_ALLOW_ALL_ORIGINS\s*=\s*True|CORS_ORIGIN_ALLOW_ALL\s*=\s*True|AllowAnyOrigin\(\)|allow_origins\s*=\s*\[\s*["']\*|add_header\s+Access-Control-Allow-Origin\s+["']?\*`)},
		&LineRule{Meta: authClientSecret, SkipComments: true, Keywords: []string{"service_role", "sb_secret", "supabase_secret", "service_key"},
			Files: func(rel, base, ext string) bool {
				return exts(".swift", ".kt", ".java", ".dart", ".tsx", ".jsx", ".vue", ".svelte", ".js", ".ts", ".html", ".plist", ".xcconfig")(rel, base, ext) && !isServerPath(rel)
			},
			Pattern: regexp.MustCompile(`(?i)service_role|SERVICE_ROLE_KEY|sb_secret_|SUPABASE_SECRET_KEY|SUPABASE_SERVICE_KEY`),
			Exclude: regexp.MustCompile(`(?i)never|must not|do not|don't`)},
		&LineRule{Meta: authDebug, Files: exts(".py", ".js", ".ts", ".rb", ".php", ".env", ".yml", ".yaml"), SkipComments: true, Keywords: []string{"debug", "allowed_hosts", "app_debug"},
			Pattern: regexp.MustCompile(`^\s*DEBUG\s*=\s*True\b|app\.run\([^)]*debug\s*=\s*True|ALLOWED_HOSTS\s*=\s*\[\s*['"]\*|APP_DEBUG\s*=\s*true|config\.consider_all_requests_local\s*=\s*true`)},
		&LineRule{Meta: authEdgeNoAuth, Files: exts(".ts", ".js"), SkipComments: true, Keywords: []string{"auth"},
			Pattern: regexp.MustCompile(`withSupabase\(\s*\{[^}]*auth\s*:\s*['"](?:none|public|optional)['"]`)},

		&LineRule{Meta: logSensitive, Files: codeMatcher, SkipComments: true,
			Keywords: []string{"log", "print", "console.", "debug", "logger", "logging"},
			Pattern:  regexp.MustCompile(`\b(?:console\.(?:log|info|debug|warn|error|trace)|print|debugPrint|dump|NSLog|os_log|logger\.\w+|Logger\(\)\.\w+|logging\.\w+|log\.\w+|Log\.[dviwe]|println|fmt\.Print\w*|puts|echo)\s*\(`),
			Check: func(m string, _ []string, line string) *RuleMeta {
				rest := strings.ToLower(line[strings.Index(line, m):])
				for _, w := range sensitiveWords {
					if i := strings.Index(rest, w); i >= 0 {
						// "password reset", "invalid token" in a literal message are fine; flag when the
						// sensitive word is part of an expression that is actually interpolated/logged.
						seg := rest[i:min(len(rest), i+40)]
						if strings.ContainsAny(seg, ")},+") || strings.Contains(rest, "\\("+w) || strings.Contains(rest, "${"+w) || strings.Contains(rest, "{"+w) {
							return logSensitive
						}
					}
				}
				return nil
			}},
		&LineRule{Meta: logLeak, Files: exts(serverExts...), SkipComments: true, Keywords: []string{"response", "res.", "jsonify", "jsonresponse", "httpresponse", "traceback", "c.json", "c.string"},
			Pattern: regexp.MustCompile(`(?:Response\.json|new\s+Response|res\.(?:send|json|end)|res\.status\([^)]*\)\.(?:send|json)|jsonify|JsonResponse|HttpResponse|c\.(?:JSON|String))\s*\(.*\b(?:err|error|e|ex|exc|exception)\.(?:message|stack|toString\(\)|Error\(\))|traceback\.format_exc\(\)|\bstr\((?:e|exc|ex|err)\)\s*[,}]`)},

		&LineRule{Meta: mobDefaults, Files: either(codeMatcher, exts(".swift", ".kt", ".java", ".dart")), SkipComments: true,
			Keywords: []string{"userdefaults", "sharedpreferences", "putstring", "asyncstorage", "localstorage", "sessionstorage"},
			Pattern:  regexp.MustCompile(`UserDefaults|@AppStorage|SharedPreferences|\.putString\(|AsyncStorage\.setItem|localStorage\.setItem|sessionStorage\.setItem`),
			Check: func(_ string, _ []string, line string) *RuleMeta {
				l := strings.ToLower(line)
				if containsAny(l, []string{"token", "password", "secret", "session", "jwt", "apikey", "api_key", "credential", "refresh", "access_key", "privatekey"}) {
					return mobDefaults
				}
				return nil
			}},
		&LineRule{Meta: mobAccessible, Files: exts(".swift", ".m", ".mm"), Keywords: []string{"ksecattraccessiblealways"},
			Pattern: regexp.MustCompile(`kSecAttrAccessibleAlways(?:ThisDeviceOnly)?\b`)},
		&LineRule{Meta: mobAndroid, Files: func(_, base, _ string) bool { return base == "AndroidManifest.xml" },
			Keywords: []string{"debuggable", "cleartexttraffic", "allowbackup"},
			Pattern:  regexp.MustCompile(`android:(?:debuggable|usesCleartextTraffic|allowBackup)\s*=\s*"true"`)},

		&LineRule{Meta: sclSyncIO, Files: func(rel, _, ext string) bool {
			return (ext == ".js" || ext == ".ts" || ext == ".mjs" || ext == ".cjs") && isServerPath(rel) && !strings.Contains(rel, "scripts/") && !strings.Contains(rel, "tools/")
		}, SkipComments: true, Keywords: []string{"sync("},
			Pattern: regexp.MustCompile(`\b(?:readFileSync|writeFileSync|execSync|spawnSync|readdirSync|existsSync|statSync)\(`)},
		&LineRule{Meta: sclUnpinnedImport, Files: exts(".ts", ".js", ".mjs", ".tsx", ".jsx", ".json"), SkipComments: true, Keywords: []string{"npm:", "jsr:", "deno.land/", "esm.sh/", "cdn.skypack.dev/", "unpkg.com/", "jsdelivr.net/"},
			Pattern: regexp.MustCompile(`['"](?:(?:npm|jsr):(@[\w.-]+/[\w.-]+|[\w.-]+)|https://(?:deno\.land/x|esm\.sh|cdn\.skypack\.dev|unpkg\.com|cdn\.jsdelivr\.net/npm)/(@[\w.-]+/[\w.-]+|[\w.-]+))((?:@[^'"/]*)?)`),
			Check: func(_ string, g []string, _ string) *RuleMeta {
				ver := g[3]
				if ver == "" || ver == "@" || ver == "@latest" || strings.HasPrefix(ver, "@^") || strings.HasPrefix(ver, "@~") || ver == "@*" {
					return sclUnpinnedImport
				}
				return nil
			}},
	)
	fileRules = append(fileRules,
		&FileRule{Files: exts(".plist"), Check: plistRule},
		&FileRule{Files: exts(".entitlements"), Check: entitlementsRule},
		&FileRule{Files: func(rel, base, _ string) bool { return base == "config.toml" && strings.Contains(rel, "supabase") }, Check: supabaseConfigRule},
		&FileRule{Files: exts(".ts", ".js", ".mjs", ".cjs", ".tsx", ".jsx", ".py"), Check: fetchTimeoutRule},
		&FileRule{Files: exts(".swift", ".ts", ".js", ".tsx", ".jsx", ".mjs", ".dart", ".kt"), Check: queryShapeRule},
	)
	projectRules = append(projectRules, privacyManifestRule)
}

var plistTrue = func(key string) *regexp.Regexp {
	return regexp.MustCompile(`<key>` + key + `</key>\s*<true\s*/>`)
}

var (
	reATSAll       = plistTrue("NSAllowsArbitraryLoads")
	reATSWeb       = plistTrue("NSAllowsArbitraryLoads(?:InWebContent|ForMedia)")
	reATSException = plistTrue("NSExceptionAllowsInsecureHTTPLoads|NSTemporaryExceptionAllowsInsecureHTTPLoads|NSThirdPartyExceptionAllowsInsecureHTTPLoads")
	reGetTask      = plistTrue("get-task-allow")
)

func plistRule(_ *Project, rel, content string) []Finding {
	var out []Finding
	for _, m := range reATSAll.FindAllStringIndex(content, -1) {
		ln := lineAt(content, m[0])
		out = append(out, mobATS.At(rel, ln, lineText(content, ln)))
	}
	for _, re := range []*regexp.Regexp{reATSWeb, reATSException} {
		for _, m := range re.FindAllStringIndex(content, -1) {
			ln := lineAt(content, m[0])
			out = append(out, mobATSException.At(rel, ln, lineText(content, ln)))
		}
	}
	return out
}

func entitlementsRule(_ *Project, rel, content string) []Finding {
	if m := reGetTask.FindStringIndex(content); m != nil {
		ln := lineAt(content, m[0])
		return []Finding{mobGetTask.At(rel, ln, lineText(content, ln))}
	}
	return nil
}

func privacyManifestRule(p *Project) []Finding {
	hasXcode := false
	for _, f := range p.Files {
		if strings.HasSuffix(f, ".xcodeproj/project.pbxproj") {
			hasXcode = true
		}
		if strings.HasSuffix(f, "PrivacyInfo.xcprivacy") {
			return nil
		}
	}
	if hasXcode {
		return []Finding{mobPrivacy.At("", 0, "")}
	}
	return nil
}

// supabaseConfigRule reads supabase/config.toml section by section.
func supabaseConfigRule(_ *Project, rel, content string) []Finding {
	var out []Finding
	section := ""
	sawMinPw := false
	inAuth := false
	for i, raw := range strings.Split(content, "\n") {
		line := strings.TrimSpace(raw)
		if j := strings.Index(line, "#"); j >= 0 && !strings.Contains(line[:j], `"`) {
			line = strings.TrimSpace(line[:j])
		}
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") {
			section = strings.Trim(line, "[] ")
			if section == "auth" {
				inAuth = true
			}
			continue
		}
		kv := strings.SplitN(line, "=", 2)
		if len(kv) != 2 {
			continue
		}
		key, val := strings.TrimSpace(kv[0]), strings.Trim(strings.TrimSpace(kv[1]), `"'`)
		at := func(m *RuleMeta) Finding { return m.At(rel, i+1, raw).with("[" + section + "]") }
		switch {
		case strings.HasPrefix(section, "functions.") && key == "verify_jwt" && val == "false":
			out = append(out, at(cfgVerifyJWT))
		case section == "auth.email" && key == "enable_confirmations" && val == "false":
			out = append(out, at(cfgConfirm))
		case section == "auth" && key == "minimum_password_length":
			sawMinPw = true
			if n, err := strconv.Atoi(val); err == nil && n < 8 {
				out = append(out, at(cfgPwLen))
			}
		case section == "auth" && key == "jwt_expiry":
			if n, err := strconv.Atoi(val); err == nil && n > 3600 {
				out = append(out, at(cfgJWTExp))
			}
		case section == "auth" && key == "enable_anonymous_sign_ins" && val == "true":
			out = append(out, at(cfgAnon))
		case section == "auth" && (key == "site_url" || key == "additional_redirect_urls") && httpURL.MatchString(val) && !httpAllowed.MatchString(val):
			out = append(out, at(cfgSiteURL))
		case section == "auth" && key == "enable_refresh_token_rotation" && val == "false":
			out = append(out, at(cfgRefreshRot))
		case section == "auth.email" && key == "secure_password_change" && val == "false":
			out = append(out, at(cfgSecurePw))
		}
	}
	if inAuth && !sawMinPw {
		out = append(out, cfgPwLen.At(rel, 0, "").with("minimum_password_length not set (Supabase default is 6)"))
	}
	return out
}

var (
	reFetchCall  = regexp.MustCompile(`\b(?:fetch|axios(?:\.(?:get|post|put|patch|delete|request))?|requests\.(?:get|post|put|patch|delete|request)|httpx\.(?:get|post)|urlopen)\s*\(`)
	reHasTimeout = regexp.MustCompile(`AbortSignal|AbortController|\bsignal\s*:|\btimeout\s*[:=]|withTimeout|\.timeout\(`)
)

// fetchTimeoutRule flags server-side files that make outbound HTTP calls but never set a timeout.
func fetchTimeoutRule(_ *Project, rel, content string) []Finding {
	if !isServerPath(rel) && !strings.HasSuffix(rel, ".py") {
		return nil
	}
	loc := reFetchCall.FindStringIndex(content)
	if loc == nil || reHasTimeout.MatchString(content) {
		return nil
	}
	ln := lineAt(content, loc[0])
	if isCommentLine(lineText(content, ln)) {
		return nil
	}
	return []Finding{sclFetchTimeout.At(rel, ln, lineText(content, ln))}
}

var (
	reFromSelect   = regexp.MustCompile(`\.from\(\s*["'\w]`)
	reBounded      = regexp.MustCompile(`\.(?:limit|range|single|maybeSingle|csv)\(|head\s*:\s*true|count\s*:\s*\.exact|\.eq\(\s*["']id["']`)
	reStatementEnd = regexp.MustCompile(`\.execute\(|\.value\b|;\s*$|^\s*$`)
	reLoopStart    = regexp.MustCompile(`^\s*(?:for\s*(?:\(|\w+\s+in\b|await\b)|while\s*[\(\w]|\w[\w.]*\.forEach\s*\()`)
	reIOCall       = regexp.MustCompile(`\bawait\b[^\n]*(?:\.from\(|\bfetch\(|\.query\(|\.execute\(|\.rpc\(|\.invoke\()`)
)

// queryShapeRule looks for unbounded Supabase/PostgREST selects and awaited I/O inside loops.
func queryShapeRule(_ *Project, rel, content string) []Finding {
	var out []Finding
	lines := strings.Split(content, "\n")
	for i := 0; i < len(lines); i++ {
		line := lines[i]
		if isCommentLine(line) {
			continue
		}
		if reFromSelect.MatchString(line) {
			// Gather the builder chain: this line plus continuation lines until the statement ends.
			chain := line
			for j := i + 1; j < len(lines) && j < i+12 && !reStatementEnd.MatchString(chain); j++ {
				chain += "\n" + lines[j]
			}
			if strings.Contains(chain, ".select(") && !reBounded.MatchString(chain) &&
				!strings.Contains(chain, ".insert(") && !strings.Contains(chain, ".upsert(") &&
				!strings.Contains(chain, ".update(") && !strings.Contains(chain, ".delete(") &&
				!suppressed(line, sclUnbounded.ID) && (i == 0 || !suppressed(lines[i-1], sclUnbounded.ID)) {
				out = append(out, sclUnbounded.At(rel, i+1, line))
			}
		}
		if reLoopStart.MatchString(line) {
			indent := len(line) - len(strings.TrimLeft(line, " \t"))
			for j := i + 1; j < len(lines) && j < i+15; j++ {
				l := lines[j]
				if strings.TrimSpace(l) == "" {
					continue
				}
				if len(l)-len(strings.TrimLeft(l, " \t")) <= indent {
					break
				}
				if reIOCall.MatchString(l) && !isCommentLine(l) {
					out = append(out, sclNPlusOne.At(rel, j+1, l))
					break
				}
			}
		}
	}
	return out
}
