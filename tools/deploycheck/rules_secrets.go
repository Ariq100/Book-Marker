package main

import (
	"encoding/base64"
	"encoding/json"
	"math"
	"path"
	"regexp"
	"strings"
)

const rotateFix = "Revoke and rotate this credential now — assume it is compromised. Load it at runtime from a secret " +
	"manager or environment variable, and add a pre-commit secret scanner so it cannot recur."

var (
	secPrivateKey = rule("SEC001", Critical, CatSecrets, "Private key committed to the repository", rotateFix)
	secAWS        = rule("SEC002", Critical, CatSecrets, "AWS access key", rotateFix)
	secGitHub     = rule("SEC003", Critical, CatSecrets, "GitHub token", rotateFix)
	secSlack      = rule("SEC004", High, CatSecrets, "Slack token", rotateFix)
	secStripe     = rule("SEC005", Critical, CatSecrets, "Stripe live secret key", rotateFix)
	secGoogle     = rule("SEC006", High, CatSecrets, "Google API key",
		"If this key ships in a client, restrict it in Google Cloud Console (API + app/bundle restrictions) and set quotas. "+
			"If it is a server key, rotate it and move it to a secret store.")
	secAIKey    = rule("SEC007", Critical, CatSecrets, "AI provider API key (OpenAI / Anthropic)", rotateFix)
	secSBSecret = rule("SEC008", Critical, CatSecrets, "Supabase secret key (bypasses Row Level Security)",
		"Rotate it in Supabase → Settings → API Keys. Secret keys belong only in server-side environments such as Edge Function secrets.")
	secJWTService = rule("SEC009", Critical, CatSecrets, "Supabase service_role JWT (bypasses Row Level Security)",
		"Rotate the JWT secret / migrate to the new API keys in Supabase → Settings → API. Never ship service_role to clients or commit it.")
	secJWT     = rule("SEC010", High, CatSecrets, "JSON Web Token committed", "Tokens in source code can be replayed. Remove it and invalidate the session or signing secret.")
	secJWTAnon = rule("SEC011", Info, CatSecrets, "Supabase anon JWT in source",
		"The anon key is public by design, but inject it via build configuration so it can be rotated without a code change.")
	secSendGrid = rule("SEC012", High, CatSecrets, "SendGrid API key", rotateFix)
	secConnStr  = rule("SEC013", High, CatSecrets, "Database/broker connection string with an embedded password",
		"Move the connection string to an environment variable or secret manager and rotate the password.")
	secConnLocal = rule("SEC014", Low, CatSecrets, "Local development connection string with a password",
		"Fine for local dev, but make sure production credentials never follow the same pattern.")
	secGeneric = rule("SEC015", Medium, CatSecrets, "Hard-coded secret-looking value",
		"Load secrets from the environment or a secret manager. If this is not a secret, add `deploycheck:ignore SEC015` on the line.")
	secTwilio = rule("SEC016", High, CatSecrets, "Twilio / Mailgun / Square API credential", rotateFix)
	secNPM    = rule("SEC017", High, CatSecrets, "Package registry token (npm / PyPI)", rotateFix)

	secEnvTracked = rule("SEC020", Critical, CatSecrets, "Environment file is committed or not gitignored", "Add it to .gitignore, `git rm --cached` it, and rotate every value it contains. Commit a `.env.example` with placeholders instead.")
	secKeyFile    = rule("SEC021", High, CatSecrets, "Key / certificate / keystore file is committed or not gitignored", "Remove it from the repository, rotate it, and distribute it through a secret manager or CI secret.")
	secCredsFile  = rule("SEC022", High, CatSecrets, "Credentials or Terraform state file is committed or not gitignored", "Remove it from the repository and rotate the credentials inside it. Store Terraform state in an encrypted remote backend.")
	secDBDump     = rule("SEC023", Medium, CatSecrets, "Database file or dump is committed or not gitignored", "Database dumps usually contain user data. Remove it from the repository and history.")
	secHistory    = rule("SEC030", High, CatSecrets, "Secret found in git history (deleted from the current code but still retrievable)", "Rotate the credential — anyone with repository access can read old commits. If the repository is or will be public, also purge it with `git filter-repo`.")
)

var placeholderRe = regexp.MustCompile(`(?i)(x{4,}|\*{3,}|your[_-]?|example|placeholder|changeme|change_me|dummy|sample|redacted|<[^>]*>|\$\{|\$\(|%\(|\{\{|test|fake|todo|replace|insert|here|none|null|undefined|password\d*$|secret\d*$|^\.\.\.)`)

func shannon(s string) float64 {
	if s == "" {
		return 0
	}
	freq := map[rune]float64{}
	for _, r := range s {
		freq[r]++
	}
	n := float64(len([]rune(s)))
	var h float64
	for _, c := range freq {
		p := c / n
		h -= p * math.Log2(p)
	}
	return h
}

func looksLikeRealSecret(v string) bool {
	if len(v) < 8 || placeholderRe.MatchString(v) {
		return false
	}
	// Words joined by _ or - ("lower_upper_letters_digits", "ownerDefaultsKey") are identifiers or
	// enum values, not credentials — random letter-only secrets that long are vanishingly rare.
	if wordsOnlyRe.MatchString(v) && (len(v) < 24 || shannon(v) < 4.0) {
		return false
	}
	var lower, upper, digit, other bool
	for _, r := range v {
		switch {
		case r >= 'a' && r <= 'z':
			lower = true
		case r >= 'A' && r <= 'Z':
			upper = true
		case r >= '0' && r <= '9':
			digit = true
		default:
			other = true
		}
	}
	classes := 0
	for _, b := range []bool{lower, upper, digit, other} {
		if b {
			classes++
		}
	}
	// Plain words, identifiers and URL paths are not secrets; random-looking strings are.
	return classes >= 2 && shannon(v) >= 3.0 && !pathLikeRe.MatchString(v)
}

// URLs, file paths, dotted identifiers (com.example.app) and format strings are not secrets.
var pathLikeRe = regexp.MustCompile(`^(?:[a-z][a-z0-9+.-]*://|[./~]|[A-Za-z_][\w-]*(?:\.[A-Za-z_][\w-]*)+$)|\.[a-z]{2,5}$|%[sd@]`)

func jwtClaims(tok string) map[string]any {
	parts := strings.Split(tok, ".")
	if len(parts) < 2 {
		return nil
	}
	b, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[1], "="))
	if err != nil {
		return nil
	}
	var m map[string]any
	if json.Unmarshal(b, &m) != nil {
		return nil
	}
	return m
}

var localHostRe = regexp.MustCompile(`@(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|db|postgres|mysql|redis|mongo|host\.docker\.internal)(?:[:/]|$)`)

// secretLineRules are also used by the git history scanner.
var secretLineRules = []*LineRule{
	{Meta: secPrivateKey, Keywords: []string{"private key"}, Redact: false,
		Pattern: regexp.MustCompile(`-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY(?: BLOCK)?-----`)},
	{Meta: secAWS, Keywords: []string{"akia", "asia"}, Redact: true,
		Pattern: regexp.MustCompile(`\b(?:AKIA|ASIA)[0-9A-Z]{16}\b`)},
	{Meta: secGitHub, Keywords: []string{"ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"}, Redact: true,
		Pattern: regexp.MustCompile(`\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})`)},
	{Meta: secSlack, Keywords: []string{"xox"}, Redact: true,
		Pattern: regexp.MustCompile(`\bxox[abposr]-[A-Za-z0-9-]{10,}`)},
	{Meta: secStripe, Keywords: []string{"_live_"}, Redact: true,
		Pattern: regexp.MustCompile(`\b(?:sk|rk)_live_[0-9A-Za-z]{20,}`)},
	{Meta: secGoogle, Keywords: []string{"aiza"}, Redact: true,
		Pattern: regexp.MustCompile(`\bAIza[0-9A-Za-z_\-]{35}\b`)},
	{Meta: secAIKey, Keywords: []string{"sk-"}, Redact: true,
		Pattern: regexp.MustCompile(`\bsk-(?:ant-[A-Za-z0-9_\-]{20,}|proj-[A-Za-z0-9_\-]{20,}|[A-Za-z0-9]{40,})`)},
	{Meta: secSBSecret, Keywords: []string{"sb_secret_"}, Redact: true,
		Pattern: regexp.MustCompile(`\bsb_secret_[A-Za-z0-9_\-]{16,}`)},
	{Meta: secJWT, Keywords: []string{"eyj"}, Redact: true,
		Pattern: regexp.MustCompile(`\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}`),
		Check: func(match string, _ []string, _ string) *RuleMeta {
			claims := jwtClaims(match)
			switch claims["role"] {
			case "service_role":
				return secJWTService
			case "anon":
				return secJWTAnon
			}
			return secJWT
		}},
	{Meta: secSendGrid, Keywords: []string{"sg."}, Redact: true,
		Pattern: regexp.MustCompile(`\bSG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}\b`)},
	{Meta: secTwilio, Keywords: []string{"ac", "key-", "sq0csp-"}, Redact: true,
		Pattern: regexp.MustCompile(`\b(?:AC[0-9a-f]{32}\b.{0,80}\b[0-9a-f]{32}\b|key-[0-9a-f]{32}\b|sq0csp-[0-9A-Za-z_\-]{43})`)},
	{Meta: secNPM, Keywords: []string{"npm_", "pypi-"}, Redact: true,
		Pattern: regexp.MustCompile(`\b(?:npm_[A-Za-z0-9]{36}|pypi-AgEIcHlwaS5vcmc[A-Za-z0-9_\-]{50,})`)},
	{Meta: secConnStr, Keywords: []string{"://"}, Redact: true,
		Pattern: regexp.MustCompile(`(?i)\b(?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|rediss?|amqps?|mssql|sqlserver)://[^:\s/@'"]+:([^@\s'"]+)@[^\s'"]*`),
		Check: func(match string, g []string, _ string) *RuleMeta {
			if placeholderRe.MatchString(g[1]) || strings.HasPrefix(g[1], "$") {
				return nil
			}
			if localHostRe.MatchString(match) {
				return secConnLocal
			}
			return secConnStr
		}},
	{Meta: secGeneric, Files: codeOrConfig, SkipComments: true, Redact: true,
		Keywords: []string{"pass", "pwd", "secret", "key", "token"},
		Pattern:  regexp.MustCompile(`(?i)\b[a-z0-9_.-]*(?:password|passwd|pwd|secret|api[_-]?key|access[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key|signing[_-]?key)[a-z0-9_]*["']?\s*(?::=|=>|=|:)\s*["']([^"'\s]{8,})["']`),
		Check: func(_ string, g []string, _ string) *RuleMeta {
			if looksLikeRealSecret(g[1]) {
				return secGeneric
			}
			return nil
		}},
}

func init() {
	lineRules = append(lineRules, secretLineRules...)
	projectRules = append(projectRules, sensitiveFiles)
}

// sensitiveFiles flags files that should never be in a repository at all, whatever they contain.
func sensitiveFiles(p *Project) []Finding {
	var out []Finding
	for _, f := range p.Files {
		base := path.Base(f)
		lb := strings.ToLower(base)
		ext := fileExt(f)
		var m *RuleMeta
		switch {
		case isEnvFile(base) && !strings.HasSuffix(lb, "example") && !strings.HasSuffix(lb, "sample") &&
			!strings.HasSuffix(lb, "template") && !strings.HasSuffix(lb, "dist") && !strings.HasSuffix(lb, "defaults"):
			m = secEnvTracked
		case ext == ".pem" || ext == ".key" || ext == ".p8" || ext == ".p12" || ext == ".pfx" || ext == ".jks" ||
			ext == ".keystore" || lb == "id_rsa" || lb == "id_ed25519" || lb == "id_ecdsa" || lb == "id_dsa" || lb == ".htpasswd":
			m = secKeyFile
		case lb == "credentials.json" || lb == "credentials" && strings.Contains(f, ".aws") ||
			strings.HasPrefix(lb, "service-account") && ext == ".json" || strings.HasSuffix(lb, "-credentials.json") ||
			strings.HasPrefix(lb, "terraform.tfstate") || ext == ".tfvars" && !strings.Contains(lb, "example") ||
			ext == ".xcconfig" && strings.Contains(lb, "secret") || lb == ".npmrc" && fileContains(p, f, "_authToken"):
			m = secCredsFile
		case ext == ".sqlite" || ext == ".sqlite3" || ext == ".db" || ext == ".dump" || ext == ".bak" ||
			strings.HasSuffix(lb, ".sql.gz") || strings.Contains(lb, "dump") && ext == ".sql":
			m = secDBDump
		}
		if m == nil {
			continue
		}
		status := "not gitignored — the next `git add -A` will commit it"
		if !p.IsGit {
			status = "present in the project folder; make sure it is excluded from version control and build artifacts"
		} else if p.Tracked[f] {
			status = "tracked in git"
		}
		out = append(out, m.At(f, 0, "").with(status))
	}
	return out
}

func fileContains(p *Project, rel, sub string) bool {
	s, err := p.Read(rel)
	return err == nil && strings.Contains(s, sub)
}

var wordsOnlyRe = regexp.MustCompile(`^[A-Za-z]+(?:[_-][A-Za-z]+)*$`)
