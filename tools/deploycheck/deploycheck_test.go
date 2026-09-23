package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Fake credentials are assembled at runtime so this file never contains a literal that secret
// scanners (including GitHub push protection) would flag.
var (
	fakeAWS    = "AKIA" + "Q3EGRTZ7" + "LMNOPQRS"
	fakeStripe = "sk_" + "live_" + "4eC39HqLyjWDarjtT1zdp7dc"
	fakeGitHub = "ghp_" + strings.Repeat("aB3dE5fG7h", 4)
	fakeSBSec  = "sb_" + "secret_" + "N7xQ2mP9vL4kR8tY1wZ6"
)

func fakeJWT(role string) string {
	enc := base64.RawURLEncoding.EncodeToString
	return enc([]byte(`{"alg":"HS256","typ":"JWT"}`)) + "." +
		enc([]byte(`{"iss":"supabase","role":"`+role+`","exp":1999999999}`)) + "." +
		enc([]byte("signature-bytes-go-here"))
}

func writeTree(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for rel, content := range files {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func scanTree(t *testing.T, root string) *Report {
	t.Helper()
	r, err := scan(&config{root: root, workers: 4, maxFileMB: 5, history: true, historyCommits: 100, minSeverity: Info, failOn: High})
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func ids(r *Report) map[string][]Finding {
	m := map[string][]Finding{}
	for _, f := range r.Findings {
		m[f.ID] = append(m[f.ID], f)
	}
	return m
}

func TestDetectsVulnerableProject(t *testing.T) {
	root := writeTree(t, map[string]string{
		"src/aws.ts":        "const creds = { accessKeyId: '" + fakeAWS + "' }\n",
		"src/pay.py":        "stripe.api_key = \"" + fakeStripe + "\"\n",
		"ci/deploy.sh":      "export GH=" + fakeGitHub + "\n",
		"app/Client.swift":  "let key = \"" + fakeJWT("service_role") + "\"\nUserDefaults.standard.set(accessToken, forKey: \"token\")\nlet url = URL(string: \"http://api.myapp.com/v1\")\nlet p = NSPredicate(format: \"name == '\\(input)'\")\n",
		"server/secret.js":  "const admin = createClient(url, '" + fakeSBSec + "')\n",
		"server/db.js":      "const url = 'postgres://admin:Pr0dPassw0rd!x@db.prod.internal.company.com:5432/app'\nconst rows = await db.query(`SELECT * FROM users WHERE id = ${req.params.id}`)\neval(req.body.code)\napp.use(cors())\nconsole.log('login', password)\nres.status(500).json({ error: err.message })\n",
		"server/config.js":  "const apiKey = \"q8Zr2LmX9vB4nT7wK1pD\"\n",
		"key.pem":           "-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----\n",
		".env":              "DATABASE_URL=something\n",
		"app/Info.plist":    "<dict>\n<key>NSAppTransportSecurity</key>\n<dict>\n<key>NSAllowsArbitraryLoads</key>\n<true/>\n</dict>\n</dict>\n",
		"App.xcodeproj/project.pbxproj": "// xcode\n",
		"supabase/config.toml": "[auth]\nminimum_password_length = 6\njwt_expiry = 86400\n[auth.email]\nenable_confirmations = false\n[functions.hook]\nverify_jwt = false\n",
		"supabase/migrations/001.sql": `
create table public.profiles (id uuid primary key, user_id uuid references auth.users(id), bio text);
create table public.posts (id bigint primary key, author_id uuid not null references public.profiles(id));
create table public.logs (msg text);
alter table public.profiles enable row level security;
create policy "own" on public.profiles for select using (auth.uid() = user_id);
create policy "open" on public.profiles for insert with check (true);
create policy "admin" on public.profiles for update using ((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin');
create view public.everything as select * from public.profiles;
create function public.do_admin() returns void language plpgsql security definer as $$ begin delete from public.posts; end; $$;
grant all on public.posts to anon;
`,
		"supabase/functions/api/index.ts": "import { serve } from 'npm:hono'\nconst r = await fetch(url)\n",
		"Dockerfile":        "FROM node:latest\nENV API_TOKEN=abc123secret\nRUN curl https://x.sh | sh\nCMD node server.js\n",
		"k8s/deploy.yaml":   "apiVersion: apps/v1\nkind: Deployment\nspec:\n  replicas: 1\n  template:\n    spec:\n      containers:\n        - name: web\n          image: myapp:latest\n          securityContext:\n            privileged: true\n",
		"infra/main.tf":     "resource \"aws_db_instance\" \"db\" {\n  publicly_accessible = true\n  storage_encrypted = false\n}\nresource \"aws_security_group_rule\" \"r\" {\n  cidr_blocks = [\"0.0.0.0/0\"]\n}\n",
		".github/workflows/ci.yml": "on: pull_request_target\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: someone/action@main\n      - run: echo \"${{ github.event.pull_request.title }}\"\n",
		"package.json":      `{"dependencies": {"left-pad": "*"}}`,
		"docker-compose.yml": "services:\n  db:\n    image: postgres:16\n    ports:\n      - \"5432:5432\"\n",
	})
	r := scanTree(t, root)
	got := ids(r)
	want := []string{
		"SEC001", "SEC002", "SEC003", "SEC005", "SEC008", "SEC009", "SEC013", "SEC015", "SEC020", "SEC021",
		"SQL001", "SQL010", "SQL011", "SQL012", "SQL013", "SQL014", "SQL020", "SQL021", "SQL030", "SQL040", "SQL050", "SQL051",
		"CFG001", "CFG002", "CFG003", "CFG005",
		"MOB001", "MOB003", "MOB006", "TRN001", "INJ001", "INJ002", "INJ003", "AUTH005", "LOG001", "LOG002",
		"SCL001", "SUP004", "SUP001", "SUP002",
		"DKR001", "DKR002", "DKR004", "DKR005", "DKR006", "DKR007", "CMP002",
		"K8S001", "K8S002", "K8S003", "K8S007", "K8S008", "K8S020",
		"TF001", "TF003", "TF004", "GHA001", "GHA002", "GHA003", "GHA004",
	}
	for _, id := range want {
		if len(got[id]) == 0 {
			t.Errorf("expected rule %s to fire", id)
		}
	}
	// Secrets must never appear unredacted in any output.
	var buf bytes.Buffer
	writeJSON(&buf, r)
	writeText(&buf, r, false, true)
	writeMarkdown(&buf, r, true)
	for _, secret := range []string{fakeAWS, fakeStripe, fakeGitHub, fakeSBSec, "Pr0dPassw0rd!x", "q8Zr2LmX9vB4nT7wK1pD"} {
		if strings.Contains(buf.String(), secret) {
			t.Errorf("secret %q leaked into report output", secret[:6])
		}
	}
}

func TestSecureProjectIsQuiet(t *testing.T) {
	root := writeTree(t, map[string]string{
		"supabase/migrations/001.sql": `
create table public.notes (id uuid primary key, user_id uuid not null references auth.users(id), body text);
create index notes_user_id_idx on public.notes (user_id);
alter table public.notes enable row level security;
alter table public.notes force row level security;
create policy "own" on public.notes for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create function private.helper() returns void language sql security definer set search_path = '' as $$ select 1 $$;
`,
		"supabase/config.toml": "[auth]\nminimum_password_length = 12\npassword_requirements = \"lower_upper_letters_digits_symbols\"\n[auth.email]\nenable_confirmations = true\n",
		"app/Api.swift":        "// never put the service_role key in the app\nlet url = URL(string: \"https://api.myapp.com\")\nlet rows = try await client.from(\"notes\").select().range(from: 0, to: 49).execute().value\nlet defaultsKey = \"lastSyncOwner\"\n",
		"server/api.ts":        "const r = await fetch(u, { signal: AbortSignal.timeout(10_000) })\nimport x from 'npm:@supabase/server@1.2.3'\nconst password = Deno.env.get('DB_PASSWORD')\n",
		".env.example":         "API_KEY=your-key-here\n",
	})
	r := scanTree(t, root)
	for _, f := range r.Findings {
		if f.Severity >= Low {
			t.Errorf("unexpected finding %s %s at %s: %s", f.ID, f.Title, f.location(), f.Detail)
		}
	}
}

func TestSuppression(t *testing.T) {
	root := writeTree(t, map[string]string{
		"a.js":               "eval(x) // deploycheck:ignore INJ001\n// deploycheck:ignore\neval(y)\neval(z)\n",
		"vendor-ish/b.js":    "eval(q)\n",
		".deploycheckignore": "vendor-ish/\nSUP001\n",
		"package.json":       "{}",
	})
	got := ids(scanTree(t, root))
	if n := len(got["INJ001"]); n != 1 {
		t.Fatalf("want exactly 1 unsuppressed INJ001 (a.js:4), got %d: %+v", n, got["INJ001"])
	}
	if got["INJ001"][0].Line != 4 {
		t.Errorf("wrong line: %d", got["INJ001"][0].Line)
	}
	if len(got["SUP001"]) != 0 {
		t.Error("SUP001 should be suppressed by .deploycheckignore")
	}
}

func TestGitHistorySecret(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	root := writeTree(t, map[string]string{"config.js": "const k = '" + fakeAWS + "'\n"})
	gitRun := func(args ...string) {
		cmd := exec.Command("git", append([]string{"-C", root, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	gitRun("init", "-q")
	gitRun("add", "-A")
	gitRun("commit", "-qm", "add key")
	os.WriteFile(filepath.Join(root, "config.js"), []byte("const k = process.env.AWS_KEY\n"), 0o644)
	gitRun("commit", "-qam", "remove key")

	got := ids(scanTree(t, root))
	if len(got["SEC002"]) != 0 {
		t.Error("key is gone from the working tree; SEC002 should not fire")
	}
	if len(got["SEC030"]) != 1 || got["SEC030"][0].Commit == "" {
		t.Fatalf("expected one SEC030 history finding with a commit, got %+v", got["SEC030"])
	}
}

func TestOutputsAreValid(t *testing.T) {
	root := writeTree(t, map[string]string{"a.js": "eval(x)\n"})
	r := scanTree(t, root)
	for name, fn := range map[string]func(*bytes.Buffer) error{
		"json":  func(b *bytes.Buffer) error { return writeJSON(b, r) },
		"sarif": func(b *bytes.Buffer) error { return writeSARIF(b, r) },
	} {
		var b bytes.Buffer
		if err := fn(&b); err != nil {
			t.Fatal(err)
		}
		var v map[string]any
		if err := json.Unmarshal(b.Bytes(), &v); err != nil {
			t.Errorf("%s output is not valid JSON: %v", name, err)
		}
	}
}

func TestExitCodes(t *testing.T) {
	root := writeTree(t, map[string]string{"a.js": "eval(x)\n"})
	var out, errb bytes.Buffer
	if c := run([]string{"--no-history", "--format", "json", root}, &out, &errb); c != 1 {
		t.Errorf("high finding with default --fail-on high: want exit 1, got %d (%s)", c, errb.String())
	}
	if c := run([]string{root, "--fail-on", "critical", "--format", "json"}, &out, &errb); c != 0 {
		t.Errorf("--fail-on critical after the path: want exit 0, got %d (%s)", c, errb.String())
	}
	if c := run([]string{"--format", "nope", root}, &out, &errb); c != 2 {
		t.Errorf("bad flag: want exit 2, got %d", c)
	}
}

func TestGlob(t *testing.T) {
	cases := []struct {
		glob, path string
		want       bool
	}{
		{"tools/deploycheck/", "tools/deploycheck/main.go", true},
		{"*.sql", "supabase/migrations/1.sql", true},
		{"supabase/*.sql", "supabase/migrations/1.sql", false},
		{"supabase/**/*.sql", "supabase/migrations/1.sql", true},
		{"node_modules", "a/node_modules/x.js", true},
		{"/build", "src/build/x", false},
	}
	for _, c := range cases {
		if got := globToRegexp(c.glob).MatchString(c.path); got != c.want {
			t.Errorf("glob %q vs %q: got %v want %v", c.glob, c.path, got, c.want)
		}
	}
}
