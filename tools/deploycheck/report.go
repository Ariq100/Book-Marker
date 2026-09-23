package main

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"
)

type Report struct {
	Tool      string         `json:"tool"`
	Version   string         `json:"version"`
	Root      string         `json:"root"`
	ScannedAt time.Time      `json:"scanned_at"`
	Duration  string         `json:"duration"`
	Stack     []string       `json:"stack"`
	Stats     reportStats    `json:"stats"`
	Summary   map[string]int `json:"summary"`
	Findings  []Finding      `json:"findings"`
	Checklist []CheckItem    `json:"checklist,omitempty"`
	Notes     []string       `json:"notes,omitempty"`
	minShow   Severity
}

type reportStats struct {
	FilesScanned   int   `json:"files_scanned"`
	FilesSkipped   int   `json:"files_skipped"`
	LinesScanned   int   `json:"lines_scanned"`
	BytesScanned   int64 `json:"bytes_scanned"`
	CommitsScanned int   `json:"commits_scanned"`
	Rules          int   `json:"rules"`
}

func (r *Report) visible() []Finding {
	var out []Finding
	for _, f := range r.Findings {
		if f.Severity >= r.minShow {
			out = append(out, f)
		}
	}
	return out
}

func (r *Report) count(s Severity) int { return r.Summary[strings.ToLower(s.String())] }

// ---- terminal ----------------------------------------------------------------------------------

type palette struct{ reset, bold, dim, red, magenta, yellow, blue, cyan, green, gray string }

func colors(on bool) palette {
	if !on {
		return palette{}
	}
	return palette{"\033[0m", "\033[1m", "\033[2m", "\033[31m", "\033[35m", "\033[33m", "\033[34m", "\033[36m", "\033[32m", "\033[90m"}
}

func (c palette) sev(s Severity) string {
	switch s {
	case Critical:
		return c.magenta + c.bold
	case High:
		return c.red + c.bold
	case Medium:
		return c.yellow
	case Low:
		return c.blue
	}
	return c.gray
}

// group collapses repeated occurrences of one rule into a single block with many locations.
type group struct {
	meta *RuleMeta
	fs   []Finding
}

func groupFindings(fs []Finding) []group {
	var gs []group
	idx := map[string]int{}
	for _, f := range fs {
		i, ok := idx[f.ID]
		if !ok {
			i = len(gs)
			idx[f.ID] = i
			gs = append(gs, group{meta: f.RuleMeta})
		}
		gs[i].fs = append(gs[i].fs, f)
	}
	return gs
}

func writeText(w io.Writer, r *Report, color bool, checklist bool) {
	c := colors(color)
	vis := r.visible()
	fmt.Fprintf(w, "\n%sdeploycheck %s%s — pre-deployment security & scalability scan\n", c.bold, r.Version, c.reset)
	fmt.Fprintf(w, "%sProject:%s %s\n", c.dim, c.reset, r.Root)
	fmt.Fprintf(w, "%sStack:%s   %s\n", c.dim, c.reset, orNone(strings.Join(r.Stack, ", ")))
	fmt.Fprintf(w, "%sScanned:%s %d files, %d lines, %d commits of history, %d rules in %s\n",
		c.dim, c.reset, r.Stats.FilesScanned, r.Stats.LinesScanned, r.Stats.CommitsScanned, r.Stats.Rules, r.Duration)
	for _, n := range r.Notes {
		fmt.Fprintf(w, "%sNote:%s    %s\n", c.dim, c.reset, n)
	}

	var cat string
	byCat := map[string][]Finding{}
	var cats []string
	for _, f := range vis {
		if _, ok := byCat[f.Category]; !ok {
			cats = append(cats, f.Category)
		}
		byCat[f.Category] = append(byCat[f.Category], f)
	}
	// Categories in order of their worst finding.
	sort.SliceStable(cats, func(i, j int) bool { return byCat[cats[i]][0].Severity > byCat[cats[j]][0].Severity })
	for _, cat = range cats {
		fmt.Fprintf(w, "\n%s━━ %s ━━%s\n", c.bold+c.cyan, cat, c.reset)
		for _, g := range groupFindings(byCat[cat]) {
			m := g.meta
			fmt.Fprintf(w, "\n %s%-8s%s %s%s%s %s(%s)%s\n", c.sev(m.Severity), m.Severity, c.reset, c.bold, m.Title, c.reset, c.gray, m.ID, c.reset)
			limit := 12
			for i, f := range g.fs {
				if i == limit {
					fmt.Fprintf(w, "          %s… and %d more%s\n", c.gray, len(g.fs)-limit, c.reset)
					break
				}
				loc := f.location()
				if loc == "" {
					loc = "(project-wide)"
				}
				fmt.Fprintf(w, "          %s%s%s", c.cyan, loc, c.reset)
				if f.Detail != "" {
					fmt.Fprintf(w, " %s— %s%s", c.gray, f.Detail, c.reset)
				}
				fmt.Fprintln(w)
				if f.Snippet != "" && len(g.fs) <= 4 {
					fmt.Fprintf(w, "            %s│ %s%s\n", c.gray, f.Snippet, c.reset)
				}
			}
			fmt.Fprintf(w, "          %sFix:%s %s\n", c.green, c.reset, wrap(m.Fix, 90, "               "))
		}
	}

	if checklist && len(r.Checklist) > 0 {
		fmt.Fprintf(w, "\n%s━━ Manual checklist (cannot be verified from code) ━━%s\n", c.bold+c.cyan, c.reset)
		area := ""
		for _, it := range r.Checklist {
			if it.Area != area {
				area = it.Area
				fmt.Fprintf(w, "\n %s%s%s\n", c.bold, area, c.reset)
			}
			fmt.Fprintf(w, "  [ ] %s\n      %s%s%s\n", wrap(it.Item, 92, "      "), c.gray, wrap(it.Why, 92, "      "), c.reset)
		}
	}

	fmt.Fprintf(w, "\n%sSummary:%s ", c.bold, c.reset)
	for s := Critical; s >= Info; s-- {
		fmt.Fprintf(w, "%s%d %s%s  ", c.sev(s), r.count(s), strings.ToLower(s.String()), c.reset)
	}
	fmt.Fprintln(w)
	if hidden := len(r.Findings) - len(vis); hidden > 0 {
		fmt.Fprintf(w, "%s(%d lower-severity findings hidden; use --min-severity info to show them)%s\n", c.gray, hidden, c.reset)
	}
	if r.count(Critical)+r.count(High) == 0 {
		fmt.Fprintf(w, "%sNo critical or high findings.%s Work through the medium items and the checklist before launch.\n", c.green+c.bold, c.reset)
	} else {
		fmt.Fprintf(w, "%sFix every critical and high finding before deploying.%s\n", c.red+c.bold, c.reset)
	}
}

func wrap(s string, width int, indent string) string {
	words := strings.Fields(s)
	var b strings.Builder
	col := 0
	for i, wd := range words {
		if i > 0 {
			if col+1+len(wd) > width {
				b.WriteString("\n" + indent)
				col = 0
			} else {
				b.WriteByte(' ')
				col++
			}
		}
		b.WriteString(wd)
		col += len(wd)
	}
	return b.String()
}

func orNone(s string) string {
	if s == "" {
		return "(not detected)"
	}
	return s
}

// ---- markdown ----------------------------------------------------------------------------------

func writeMarkdown(w io.Writer, r *Report, checklist bool) {
	vis := r.visible()
	fmt.Fprintf(w, "# deploycheck report\n\n")
	fmt.Fprintf(w, "- **Project:** `%s`\n- **Scanned:** %s (%s)\n- **Stack:** %s\n- **Coverage:** %d files, %d lines, %d commits, %d rules\n\n",
		r.Root, r.ScannedAt.Format(time.RFC1123), r.Duration, orNone(strings.Join(r.Stack, ", ")),
		r.Stats.FilesScanned, r.Stats.LinesScanned, r.Stats.CommitsScanned, r.Stats.Rules)
	for _, n := range r.Notes {
		fmt.Fprintf(w, "> %s\n\n", n)
	}
	fmt.Fprintf(w, "| Critical | High | Medium | Low | Info |\n|---|---|---|---|---|\n| %d | %d | %d | %d | %d |\n\n",
		r.count(Critical), r.count(High), r.count(Medium), r.count(Low), r.count(Info))
	if len(vis) == 0 {
		fmt.Fprintf(w, "No findings at the selected severity.\n\n")
	}
	for _, g := range groupFindings(vis) {
		m := g.meta
		fmt.Fprintf(w, "## %s — %s\n\n`%s` · %s\n\n", m.Severity, m.Title, m.ID, m.Category)
		for _, f := range g.fs {
			loc := f.location()
			if loc == "" {
				loc = "project-wide"
			}
			fmt.Fprintf(w, "- `%s`", loc)
			if f.Detail != "" {
				fmt.Fprintf(w, " — %s", f.Detail)
			}
			if f.Snippet != "" {
				fmt.Fprintf(w, "\n  `%s`", strings.ReplaceAll(f.Snippet, "`", "'"))
			}
			fmt.Fprintln(w)
		}
		fmt.Fprintf(w, "\n**Fix:** %s\n\n", m.Fix)
	}
	if checklist && len(r.Checklist) > 0 {
		fmt.Fprintf(w, "## Manual checklist\n\nThese cannot be verified from source code. Tick them off before launch.\n\n")
		area := ""
		for _, it := range r.Checklist {
			if it.Area != area {
				area = it.Area
				fmt.Fprintf(w, "\n### %s\n\n", area)
			}
			fmt.Fprintf(w, "- [ ] %s  \n  _%s_\n", it.Item, it.Why)
		}
	}
}

// ---- JSON / SARIF ------------------------------------------------------------------------------

func writeJSON(w io.Writer, r *Report) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	cp := *r
	cp.Findings = r.visible()
	if cp.Findings == nil {
		cp.Findings = []Finding{}
	}
	return enc.Encode(cp)
}

func writeSARIF(w io.Writer, r *Report) error {
	type msg struct {
		Text string `json:"text"`
	}
	type sarifRule struct {
		ID               string         `json:"id"`
		Name             string         `json:"name"`
		ShortDescription msg            `json:"shortDescription"`
		Help             msg            `json:"help"`
		Properties       map[string]any `json:"properties"`
	}
	type region struct {
		StartLine int `json:"startLine"`
	}
	type physical struct {
		ArtifactLocation struct {
			URI string `json:"uri"`
		} `json:"artifactLocation"`
		Region *region `json:"region,omitempty"`
	}
	type location struct {
		PhysicalLocation physical `json:"physicalLocation"`
	}
	type result struct {
		RuleID    string     `json:"ruleId"`
		Level     string     `json:"level"`
		Message   msg        `json:"message"`
		Locations []location `json:"locations,omitempty"`
	}
	scores := map[Severity]string{Critical: "9.5", High: "8.0", Medium: "5.5", Low: "3.0", Info: "1.0"}
	levels := map[Severity]string{Critical: "error", High: "error", Medium: "warning", Low: "note", Info: "note"}

	var rules []sarifRule
	seen := map[string]bool{}
	var results []result
	for _, f := range r.visible() {
		if !seen[f.ID] {
			seen[f.ID] = true
			rules = append(rules, sarifRule{ID: f.ID, Name: f.ID, ShortDescription: msg{f.Title}, Help: msg{f.Fix},
				Properties: map[string]any{"security-severity": scores[f.Severity], "tags": []string{"security", f.Category}}})
		}
		text := f.Title
		if f.Detail != "" {
			text += " — " + f.Detail
		}
		res := result{RuleID: f.ID, Level: levels[f.Severity], Message: msg{text}}
		if f.File != "" && !strings.Contains(f.File, "://") {
			var pl physical
			pl.ArtifactLocation.URI = f.File
			if f.Line > 0 {
				pl.Region = &region{f.Line}
			}
			res.Locations = []location{{pl}}
		}
		results = append(results, res)
	}
	if results == nil {
		results = []result{}
	}
	doc := map[string]any{
		"$schema": "https://json.schemastore.org/sarif-2.1.0.json",
		"version": "2.1.0",
		"runs": []any{map[string]any{
			"tool":    map[string]any{"driver": map[string]any{"name": "deploycheck", "version": r.Version, "rules": rules}},
			"results": results,
		}},
	}
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(doc)
}
