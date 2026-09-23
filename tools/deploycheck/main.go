// deploycheck scans a project for the security and scalability problems that matter when an app
// is deployed to real users at scale: leaked secrets (including git history), database access
// control (Supabase RLS, grants, SECURITY DEFINER), injection, transport security, mobile storage,
// container/Kubernetes/Terraform/CI misconfiguration, and code patterns that fall over under load.
// Optional live checks probe a deployed site and Supabase project read-only.
//
// Usage: deploycheck [flags] [path]   — run `deploycheck -h` for flags.
// Double-clicking the binary starts an interactive session.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"
)

var version = "1.0.0"

type config struct {
	root           string
	format         string
	out            string
	failOn         Severity
	minSeverity    Severity
	history        bool
	historyCommits int
	checklist      bool
	workers        int
	maxFileMB      int
	color          bool
	live           liveTarget
}

func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }

func run(args []string, stdout, stderr io.Writer) int {
	interactive := len(args) == 0 && isTerminal(os.Stdin)
	cfg, code := parseArgs(args, stderr)
	if code >= 0 {
		return code
	}
	if interactive {
		defer pauseIfDoubleClicked()
		promptInteractive(cfg, stdout)
	}

	abs, err := filepath.Abs(cfg.root)
	if err == nil {
		cfg.root = abs
	}
	if info, err := os.Stat(cfg.root); err != nil || !info.IsDir() {
		fmt.Fprintf(stderr, "deploycheck: %q is not a folder\n", cfg.root)
		return 2
	}

	report, err := scan(cfg)
	if err != nil {
		fmt.Fprintf(stderr, "deploycheck: %v\n", err)
		return 2
	}

	var w io.Writer = stdout
	if cfg.out != "" {
		f, err := os.Create(cfg.out)
		if err != nil {
			fmt.Fprintf(stderr, "deploycheck: %v\n", err)
			return 2
		}
		defer f.Close()
		w = f
	}
	switch cfg.format {
	case "json":
		err = writeJSON(w, report)
	case "sarif":
		err = writeSARIF(w, report)
	case "markdown", "md":
		writeMarkdown(w, report, cfg.checklist)
	default:
		writeText(w, report, cfg.color && cfg.out == "", cfg.checklist)
	}
	if err != nil {
		fmt.Fprintf(stderr, "deploycheck: %v\n", err)
		return 2
	}
	if cfg.out != "" {
		fmt.Fprintf(stderr, "Report written to %s\n", cfg.out)
	}
	if interactive {
		// A double-clicked console window disappears when the program exits, so keep a copy.
		mdPath := filepath.Join(cfg.root, "deploycheck-report.md")
		if f, err := os.Create(mdPath); err == nil {
			writeMarkdown(f, report, true)
			f.Close()
			fmt.Fprintf(stdout, "\nFull report saved to %s\n", mdPath)
		}
	}

	for _, f := range report.Findings {
		if f.Severity >= cfg.failOn {
			return 1
		}
	}
	return 0
}

func parseArgs(args []string, stderr io.Writer) (*config, int) {
	cfg := &config{root: "."}
	fs := flag.NewFlagSet("deploycheck", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&cfg.format, "format", "text", "output format: text, markdown, json, sarif")
	fs.StringVar(&cfg.out, "out", "", "write the report to this file instead of stdout")
	failOn := fs.String("fail-on", "high", "exit with code 1 if any finding is at or above this severity (info|low|medium|high|critical|none)")
	minSev := fs.String("min-severity", "low", "hide findings below this severity (info|low|medium|high|critical)")
	noHistory := fs.Bool("no-history", false, "skip scanning git history for deleted secrets")
	fs.IntVar(&cfg.historyCommits, "history-commits", 5000, "maximum number of commits of history to scan (0 = all)")
	noChecklist := fs.Bool("no-checklist", false, "omit the manual pre-launch checklist")
	fs.IntVar(&cfg.workers, "workers", runtime.NumCPU(), "parallel file scanners")
	fs.IntVar(&cfg.maxFileMB, "max-file-mb", 5, "skip files larger than this many MB")
	noColor := fs.Bool("no-color", false, "disable colored output")
	fs.StringVar(&cfg.live.URL, "url", "", "live-check a deployed site (comma-separate several); read-only requests")
	fs.StringVar(&cfg.live.SupabaseURL, "supabase-url", os.Getenv("SUPABASE_URL"), "live-check a Supabase project, e.g. https://abc.supabase.co (env SUPABASE_URL)")
	fs.StringVar(&cfg.live.SupabaseKey, "supabase-key", firstNonEmpty(os.Getenv("SUPABASE_ANON_KEY"), os.Getenv("SUPABASE_PUBLISHABLE_KEY")), "the PUBLIC anon/publishable key for --supabase-url (env SUPABASE_ANON_KEY)")
	fs.BoolVar(&cfg.live.ProbeFunctions, "probe-functions", false, "also call each Edge Function without a user session to confirm it rejects the request")
	timeout := fs.Duration("timeout", 10*time.Second, "timeout for each live-check request")
	listRules := fs.Bool("list-rules", false, "print every rule and exit")
	showVersion := fs.Bool("version", false, "print the version and exit")
	fs.Usage = func() {
		fmt.Fprintf(stderr, "deploycheck %s — security & scalability checks before you deploy\n\n", version)
		fmt.Fprintf(stderr, "Usage:\n  deploycheck [flags] [project-folder]\n\nExamples:\n")
		fmt.Fprintf(stderr, "  deploycheck .                                   scan the current folder\n")
		fmt.Fprintf(stderr, "  deploycheck --format sarif --out ds.sarif .     for GitHub code scanning\n")
		fmt.Fprintf(stderr, "  deploycheck --url https://myapp.com .           add live header/TLS/CORS checks\n")
		fmt.Fprintf(stderr, "  deploycheck --supabase-url https://x.supabase.co --supabase-key sb_publishable_... .\n\n")
		fmt.Fprintf(stderr, "Exit codes: 0 = clean, 1 = findings at/above --fail-on, 2 = error.\n")
		fmt.Fprintf(stderr, "Suppress: add `deploycheck:ignore [RULE-ID]` on or above a line, or list rule IDs / paths in .deploycheckignore.\n\nFlags:\n")
		fs.PrintDefaults()
	}

	// Allow flags both before and after the path (Go's flag package stops at the first positional).
	rest := args
	for {
		if err := fs.Parse(rest); err != nil {
			if err == flag.ErrHelp {
				return nil, 0
			}
			return nil, 2
		}
		if fs.NArg() == 0 {
			break
		}
		cfg.root = fs.Arg(0)
		rest = fs.Args()[1:]
		if len(rest) == 0 {
			break
		}
	}

	if *showVersion {
		fmt.Fprintln(os.Stdout, "deploycheck", version)
		return nil, 0
	}
	if *listRules {
		printRules(os.Stdout)
		return nil, 0
	}
	var err error
	if cfg.failOn, err = parseSeverity(*failOn); err != nil {
		fmt.Fprintln(stderr, "deploycheck:", err)
		return nil, 2
	}
	if cfg.minSeverity, err = parseSeverity(*minSev); err != nil || cfg.minSeverity == never {
		fmt.Fprintln(stderr, "deploycheck: invalid --min-severity")
		return nil, 2
	}
	switch cfg.format {
	case "text", "json", "sarif", "markdown", "md":
	default:
		fmt.Fprintf(stderr, "deploycheck: unknown --format %q\n", cfg.format)
		return nil, 2
	}
	cfg.history = !*noHistory
	cfg.checklist = !*noChecklist
	cfg.live.Timeout = *timeout
	cfg.color = !*noColor && os.Getenv("NO_COLOR") == "" && isTerminal(os.Stdout) && enableANSI()
	return cfg, -1
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

func isTerminal(f *os.File) bool {
	info, err := f.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

func promptInteractive(cfg *config, out io.Writer) {
	in := bufio.NewReader(os.Stdin)
	ask := func(q string) string {
		fmt.Fprint(out, q)
		s, _ := in.ReadString('\n')
		return cleanDroppedPath(s)
	}
	cwd, _ := os.Getwd()
	fmt.Fprintf(out, "deploycheck %s — security & scalability scan\n\n", version)
	if p := ask(fmt.Sprintf("Project folder to scan (drag it here, or press Enter for %s): ", cwd)); p != "" {
		cfg.root = p
	}
	if u := ask("Deployed site URL to live-check (optional, press Enter to skip): "); u != "" {
		cfg.live.URL = u
	}
	if cfg.live.SupabaseURL == "" {
		if u := ask("Supabase project URL to live-check (optional, press Enter to skip): "); u != "" {
			cfg.live.SupabaseURL = u
			cfg.live.SupabaseKey = ask("Supabase PUBLIC anon/publishable key: ")
		}
	}
	fmt.Fprintln(out)
}

// cleanDroppedPath undoes the quoting terminals apply to drag-and-dropped paths.
func cleanDroppedPath(s string) string {
	s = strings.TrimSpace(s)
	s = strings.Trim(s, `"'`)
	if runtime.GOOS != "windows" {
		s = strings.ReplaceAll(s, `\ `, " ")
	}
	return s
}

func pauseIfDoubleClicked() {
	if runtime.GOOS != "windows" {
		return
	}
	fmt.Print("\nPress Enter to close...")
	bufio.NewReader(os.Stdin).ReadString('\n')
}

func printRules(w io.Writer) {
	var ids []string
	for id := range catalog {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		m := catalog[id]
		fmt.Fprintf(w, "%-26s %-8s %-26s %s\n", id, m.Severity, m.Category, m.Title)
	}
	fmt.Fprintf(w, "\n%d rules\n", len(ids))
}

func scan(cfg *config) (*Report, error) {
	start := time.Now()
	ig, err := loadIgnoreFile(cfg.root)
	if err != nil {
		return nil, fmt.Errorf("reading .deploycheckignore: %w", err)
	}
	p, err := discover(cfg.root, ig)
	if err != nil {
		return nil, err
	}
	r := &Report{Tool: "deploycheck", Version: version, Root: cfg.root, ScannedAt: start, Stack: p.stackList(), minShow: cfg.minSeverity}
	if !p.IsGit {
		r.Notes = append(r.Notes, "Not a git repository (or git is not installed): git history was not scanned and .gitignore support is basic.")
	}

	var mu sync.Mutex
	var all []Finding
	add := func(fs []Finding) {
		mu.Lock()
		all = append(all, fs...)
		mu.Unlock()
	}

	// File scan, project rules and live checks are independent — run them concurrently.
	var wg sync.WaitGroup
	var fileFindings []Finding
	var st scanStats
	wg.Add(1)
	go func() {
		defer wg.Done()
		fileFindings, st = scanFiles(p, cfg.workers, int64(cfg.maxFileMB)<<20)
		add(fileFindings)
	}()
	for _, pr := range projectRules {
		wg.Add(1)
		go func(pr ProjectRule) { defer wg.Done(); add(pr(p)) }(pr)
	}
	if cfg.live.URL != "" || cfg.live.SupabaseURL != "" {
		if cfg.live.SupabaseURL != "" && cfg.live.SupabaseKey == "" {
			r.Notes = append(r.Notes, "--supabase-url given without --supabase-key; Supabase live checks skipped.")
		}
		wg.Add(1)
		go func() { defer wg.Done(); add(runLive(cfg.live, p)) }()
	}
	wg.Wait()

	// History needs the working-tree results so it only reports secrets that are gone from the code.
	commits := 0
	if cfg.history {
		var hf []Finding
		hf, commits = scanHistory(p, cfg.historyCommits, fileFindings)
		all = append(all, hf...)
	}

	var kept []Finding
	for _, f := range all {
		if !ig.suppresses(f) {
			kept = append(kept, f)
		}
	}
	kept = dedupe(kept)
	sortFindings(kept)

	r.Findings = kept
	r.Summary = map[string]int{"critical": 0, "high": 0, "medium": 0, "low": 0, "info": 0}
	for _, f := range kept {
		r.Summary[strings.ToLower(f.Severity.String())]++
	}
	r.Stats = reportStats{FilesScanned: st.Files, FilesSkipped: st.Skipped, LinesScanned: st.Lines, BytesScanned: st.Bytes,
		CommitsScanned: commits, Rules: len(catalog)}
	if cfg.checklist {
		r.Checklist = checklistFor(p)
	}
	r.Duration = time.Since(start).Round(time.Millisecond).String()
	return r, nil
}
