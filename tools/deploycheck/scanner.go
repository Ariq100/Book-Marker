package main

import (
	"bufio"
	"bytes"
	"io/fs"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
)

// LineRule matches a regular expression against every line of the files it applies to.
// Keywords is a cheap lowercase pre-filter so the regex only runs on lines that could match —
// that is what keeps the scan linear and fast on very large repositories.
type LineRule struct {
	Meta         *RuleMeta
	Files        func(rel, base, ext string) bool // nil = every text file
	Keywords     []string
	Pattern      *regexp.Regexp
	Exclude      *regexp.Regexp                                             // line is skipped if this matches
	Check        func(match string, groups []string, line string) *RuleMeta // refine or veto a match
	Redact       bool                                                       // never print the matched value
	SkipComments bool
}

// FileRule sees a whole file at once, for checks that span lines (plists, Dockerfiles, manifests).
type FileRule struct {
	Files func(rel, base, ext string) bool
	Check func(p *Project, rel string, content string) []Finding
}

// ProjectRule sees the whole project, for checks that correlate files (SQL migrations, lockfiles).
type ProjectRule func(p *Project) []Finding

var (
	lineRules    []*LineRule
	fileRules    []*FileRule
	projectRules []ProjectRule
)

// Project is the set of files under scan plus what the scanner learned about the stack.
type Project struct {
	Root    string
	Files   []string        // slash-separated, relative to Root
	Tracked map[string]bool // files committed to git; nil when Root is not a git work tree
	IsGit   bool
	Stack   map[string]bool
	ignore  *ignoreList
}

func (p *Project) Read(rel string) (string, error) {
	b, err := os.ReadFile(filepath.Join(p.Root, filepath.FromSlash(rel)))
	return string(b), err
}

func (p *Project) filesWhere(match func(rel, base, ext string) bool) []string {
	var out []string
	for _, f := range p.Files {
		if match(f, path.Base(f), fileExt(f)) {
			out = append(out, f)
		}
	}
	return out
}

func (p *Project) has(rel string) bool {
	i := sort.SearchStrings(p.Files, rel)
	return i < len(p.Files) && p.Files[i] == rel
}

var excludedDirs = map[string]bool{
	".git": true, "node_modules": true, "vendor": true, "dist": true, "build": true, ".build": true,
	"DerivedData": true, "Pods": true, "Carthage": true, ".next": true, ".nuxt": true, ".svelte-kit": true,
	"target": true, "__pycache__": true, ".venv": true, "venv": true, ".terraform": true,
	"coverage": true, ".gradle": true, ".idea": true, "bower_components": true, ".turbo": true,
	".cache": true, ".output": true, "xcuserdata": true,
}

// Generated or binary files: scanning them costs time and produces only noise.
var skippedNames = map[string]bool{
	"package-lock.json": true, "yarn.lock": true, "pnpm-lock.yaml": true, "bun.lockb": true, "bun.lock": true,
	"Package.resolved": true, "go.sum": true, "Cargo.lock": true, "poetry.lock": true, "composer.lock": true,
	"Gemfile.lock": true, "deno.lock": true, "Podfile.lock": true, ".DS_Store": true,
	"deploycheck-report.md": true, "deploycheck-report.json": true, "deploycheck-report.sarif": true,
}

var binaryExts = map[string]bool{
	".png": true, ".jpg": true, ".jpeg": true, ".gif": true, ".webp": true, ".ico": true, ".icns": true,
	".bmp": true, ".tiff": true, ".heic": true, ".pdf": true, ".zip": true, ".gz": true, ".tgz": true,
	".tar": true, ".7z": true, ".rar": true, ".woff": true, ".woff2": true, ".ttf": true, ".otf": true,
	".eot": true, ".mp3": true, ".mp4": true, ".mov": true, ".wav": true, ".m4a": true, ".avi": true,
	".xcuserstate": true, ".a": true, ".o": true, ".so": true, ".dylib": true, ".dll": true, ".exe": true,
	".jar": true, ".class": true, ".pyc": true, ".wasm": true, ".car": true, ".nib": true, ".psd": true,
	".sketch": true, ".fig": true, ".map": true,
}

func fileExt(rel string) string { return strings.ToLower(path.Ext(rel)) }

func skipPath(rel string) bool {
	parts := strings.Split(rel, "/")
	for _, d := range parts[:len(parts)-1] {
		if excludedDirs[d] {
			return true
		}
	}
	base := parts[len(parts)-1]
	if skippedNames[base] || binaryExts[fileExt(base)] {
		return true
	}
	return strings.HasSuffix(base, ".min.js") || strings.HasSuffix(base, ".min.css")
}

func gitCmd(root string, args ...string) ([]byte, error) {
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	cmd.Stderr = nil
	return cmd.Output()
}

func splitNUL(b []byte) []string {
	var out []string
	for _, s := range bytes.Split(b, []byte{0}) {
		if len(s) > 0 {
			out = append(out, string(s))
		}
	}
	return out
}

func discover(root string, ig *ignoreList) (*Project, error) {
	p := &Project{Root: root, Stack: map[string]bool{}, ignore: ig}
	var files []string
	// Inside a git work tree, let git decide what belongs to the project: tracked files plus
	// untracked files that are not ignored — i.e. exactly what the next `git add -A` would ship.
	if out, err := gitCmd(root, "ls-files", "-co", "--exclude-standard", "-z"); err == nil {
		p.IsGit = true
		files = splitNUL(out)
		if tr, err := gitCmd(root, "ls-files", "-z"); err == nil {
			p.Tracked = map[string]bool{}
			for _, f := range splitNUL(tr) {
				p.Tracked[f] = true
			}
		}
	} else {
		var werr error
		files, werr = walk(root)
		if werr != nil {
			return nil, werr
		}
	}
	for _, f := range files {
		if skipPath(f) || ig.excludesPath(f) {
			continue
		}
		p.Files = append(p.Files, f)
	}
	sort.Strings(p.Files)
	p.detectStack()
	return p, nil
}

// walk lists files when git is unavailable, honoring the root .gitignore's simple patterns.
func walk(root string) ([]string, error) {
	gi := &ignoreList{}
	if b, err := os.ReadFile(filepath.Join(root, ".gitignore")); err == nil {
		gi = parseGitignore(string(b))
	}
	var files []string
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // unreadable entry: skip it, keep walking
		}
		rel, _ := filepath.Rel(root, p)
		rel = filepath.ToSlash(rel)
		if d.IsDir() {
			if rel != "." && (excludedDirs[d.Name()] || gi.excludesPath(rel+"/")) {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Type().IsRegular() && !gi.excludesPath(rel) {
			files = append(files, rel)
		}
		return nil
	})
	return files, err
}

func (p *Project) detectStack() {
	for _, f := range p.Files {
		base, ext := path.Base(f), fileExt(f)
		switch {
		case strings.HasPrefix(f, "supabase/") || strings.Contains(f, "/supabase/"):
			p.Stack["supabase"] = true
		case ext == ".swift" || strings.Contains(f, ".xcodeproj/"):
			p.Stack["ios"] = true
		case base == "AndroidManifest.xml" || ext == ".kt" || base == "build.gradle" || base == "build.gradle.kts":
			p.Stack["android"] = true
		case base == "package.json":
			p.Stack["node"] = true
		case ext == ".py" || base == "requirements.txt" || base == "pyproject.toml":
			p.Stack["python"] = true
		case base == "go.mod":
			p.Stack["go"] = true
		case isDockerfile(base):
			p.Stack["docker"] = true
		case ext == ".tf":
			p.Stack["terraform"] = true
		case strings.HasPrefix(f, ".github/workflows/"):
			p.Stack["github-actions"] = true
		case ext == ".sql":
			p.Stack["sql"] = true
		}
		if ext == ".yaml" || ext == ".yml" {
			if s, err := p.Read(f); err == nil && len(s) < 1<<20 && k8sKind.MatchString(s) {
				p.Stack["kubernetes"] = true
			}
		}
	}
}

func (p *Project) stackList() []string {
	var s []string
	for k := range p.Stack {
		s = append(s, k)
	}
	sort.Strings(s)
	return s
}

type scanStats struct {
	Files, Skipped, Lines int
	Bytes                 int64
}

const maxLineLen = 20000

// scanFiles runs line and file rules over every file with a pool of workers. Memory stays bounded
// at roughly workers × maxSize no matter how large the repository is.
func scanFiles(p *Project, workers int, maxSize int64) ([]Finding, scanStats) {
	if workers <= 0 {
		workers = runtime.NumCPU()
	}
	jobs := make(chan string, workers*4)
	type result struct {
		findings []Finding
		lines    int
		bytes    int64
		skipped  bool
	}
	results := make(chan result, workers*4)
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for rel := range jobs {
				fs, lines, n, ok := scanOne(p, rel, maxSize)
				results <- result{fs, lines, n, !ok}
			}
		}()
	}
	go func() {
		for _, f := range p.Files {
			jobs <- f
		}
		close(jobs)
		wg.Wait()
		close(results)
	}()
	var all []Finding
	var st scanStats
	for r := range results {
		if r.skipped {
			st.Skipped++
			continue
		}
		st.Files++
		st.Lines += r.lines
		st.Bytes += r.bytes
		all = append(all, r.findings...)
	}
	return all, st
}

func scanOne(p *Project, rel string, maxSize int64) ([]Finding, int, int64, bool) {
	full := filepath.Join(p.Root, filepath.FromSlash(rel))
	info, err := os.Stat(full)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxSize {
		return nil, 0, 0, false
	}
	data, err := os.ReadFile(full)
	if err != nil || isBinary(data) {
		return nil, 0, 0, false
	}
	content := string(data)
	base, ext := path.Base(rel), fileExt(rel)

	var findings []Finding
	var active []*LineRule
	for _, r := range lineRules {
		if r.Files == nil || r.Files(rel, base, ext) {
			active = append(active, r)
		}
	}
	lines := strings.Split(content, "\n")
	if len(active) > 0 {
		prev := ""
		for i, line := range lines {
			if len(line) > maxLineLen {
				line = line[:maxLineLen]
			}
			lower := strings.ToLower(line)
			comment := isCommentLine(line)
			for _, r := range active {
				if r.SkipComments && comment {
					continue
				}
				if len(r.Keywords) > 0 && !containsAny(lower, r.Keywords) {
					continue
				}
				loc := r.Pattern.FindStringSubmatchIndex(line)
				if loc == nil {
					continue
				}
				if r.Exclude != nil && r.Exclude.MatchString(line) {
					continue
				}
				if suppressed(line, r.Meta.ID) || suppressed(prev, r.Meta.ID) {
					continue
				}
				match := line[loc[0]:loc[1]]
				groups := make([]string, 0, len(loc)/2)
				for g := 0; g+1 < len(loc); g += 2 {
					if loc[g] >= 0 {
						groups = append(groups, line[loc[g]:loc[g+1]])
					} else {
						groups = append(groups, "")
					}
				}
				meta := r.Meta
				if r.Check != nil {
					if meta = r.Check(match, groups, line); meta == nil {
						continue
					}
				}
				snippet := line
				if r.Redact {
					snippet = redactLine(line, loc)
				}
				findings = append(findings, meta.At(rel, i+1, snippet))
			}
			prev = line
		}
	}
	for _, r := range fileRules {
		if r.Files(rel, base, ext) {
			for _, f := range r.Check(p, rel, content) {
				if f.Line > 0 && f.Line <= len(lines) && (suppressed(lines[f.Line-1], f.ID) || (f.Line > 1 && suppressed(lines[f.Line-2], f.ID))) {
					continue
				}
				findings = append(findings, f)
			}
		}
	}
	return findings, len(lines), int64(len(data)), true
}

func isBinary(b []byte) bool {
	n := len(b)
	if n > 8000 {
		n = 8000
	}
	return bytes.IndexByte(b[:n], 0) >= 0
}

func isCommentLine(line string) bool {
	t := strings.TrimSpace(line)
	for _, pre := range []string{"//", "#", "*", "/*", "--", "<!--", ";"} {
		if strings.HasPrefix(t, pre) {
			return true
		}
	}
	return false
}

func containsAny(s string, subs []string) bool {
	for _, sub := range subs {
		if strings.Contains(s, sub) {
			return true
		}
	}
	return false
}

// suppressed honors inline `deploycheck:ignore` (all rules) or `deploycheck:ignore SEC013,SQL011`.
func suppressed(line, id string) bool {
	i := strings.Index(line, "deploycheck:ignore")
	if i < 0 {
		return false
	}
	rest := strings.TrimSpace(line[i+len("deploycheck:ignore"):])
	if rest == "" || !ruleIDPattern.MatchString(strings.FieldsFunc(rest, splitIDs)[0]) {
		return true
	}
	for _, f := range strings.FieldsFunc(rest, splitIDs) {
		if f == id {
			return true
		}
	}
	return false
}

func splitIDs(r rune) bool { return r == ',' || r == ' ' || r == '\t' }

// redactLine masks the secret in a matched line: capture group 1 when the rule has one (so the
// variable name stays readable), otherwise the whole match.
func redactLine(line string, loc []int) string {
	a, b := loc[0], loc[1]
	if len(loc) >= 4 && loc[2] >= 0 {
		a, b = loc[2], loc[3]
	}
	return line[:a] + redact(line[a:b]) + line[b:]
}

func redact(s string) string {
	r := []rune(s)
	if len(r) <= 8 {
		return "[REDACTED]"
	}
	return string(r[:4]) + "…[REDACTED " + itoa(len(r)) + " chars]"
}

func itoa(n int) string {
	var b [20]byte
	i := len(b)
	if n == 0 {
		return "0"
	}
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

// lineAt converts a byte offset to a 1-based line number.
func lineAt(content string, offset int) int {
	if offset > len(content) {
		offset = len(content)
	}
	return strings.Count(content[:offset], "\n") + 1
}

func lineText(content string, line int) string {
	sc := bufio.NewScanner(strings.NewReader(content))
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for n := 1; sc.Scan(); n++ {
		if n == line {
			return sc.Text()
		}
	}
	return ""
}

// ---- file matchers -------------------------------------------------------------------------

func exts(list ...string) func(rel, base, ext string) bool {
	set := map[string]bool{}
	for _, e := range list {
		set[e] = true
	}
	return func(_, _, ext string) bool { return set[ext] }
}

var (
	jsExts     = []string{".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts", ".vue", ".svelte"}
	serverExts = []string{".js", ".mjs", ".cjs", ".ts", ".mts", ".cts", ".py", ".rb", ".go", ".java", ".kt", ".cs", ".php", ".rs"}
	codeExts   = []string{".swift", ".m", ".mm", ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts", ".vue", ".svelte",
		".py", ".rb", ".go", ".java", ".kt", ".kts", ".cs", ".php", ".dart", ".rs", ".scala", ".ex", ".exs"}
	configExts = []string{".yml", ".yaml", ".json", ".toml", ".ini", ".cfg", ".conf", ".properties", ".xcconfig",
		".plist", ".env", ".tf", ".tfvars", ".sh", ".bash", ".zsh", ".ps1", ".xml", ".gradle"}
)

func codeOrConfig(rel, base, ext string) bool {
	return exts(append(append([]string{}, codeExts...), configExts...)...)(rel, base, ext) ||
		isEnvFile(base) || isDockerfile(base)
}

var codeMatcher = exts(codeExts...)

func isEnvFile(base string) bool { return base == ".env" || strings.HasPrefix(base, ".env.") }

func isDockerfile(base string) bool {
	return base == "Dockerfile" || strings.HasPrefix(base, "Dockerfile.") || strings.HasSuffix(base, ".dockerfile") || base == "Containerfile"
}

func either(fns ...func(rel, base, ext string) bool) func(rel, base, ext string) bool {
	return func(rel, base, ext string) bool {
		for _, f := range fns {
			if f(rel, base, ext) {
				return true
			}
		}
		return false
	}
}

// isServerPath guesses whether a file runs on a server rather than ships to users' devices/browsers.
func isServerPath(rel string) bool {
	l := strings.ToLower(rel)
	for _, s := range []string{"supabase/functions/", "functions/", "server", "api/", "backend", "scripts/",
		"migrations/", "lambda", "worker", "cmd/", "internal/", "cron", "jobs/", "tools/", ".github/"} {
		if strings.Contains(l, s) {
			return true
		}
	}
	return false
}
