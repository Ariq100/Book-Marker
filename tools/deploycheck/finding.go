package main

import (
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// Severity orders findings from purely informational to "fix before you ship".
type Severity int

const (
	Info Severity = iota
	Low
	Medium
	High
	Critical
	// never is only used as a --fail-on threshold that nothing reaches.
	never
)

var severityNames = []string{"INFO", "LOW", "MEDIUM", "HIGH", "CRITICAL"}

func (s Severity) String() string {
	if s < Info || s > Critical {
		return "NONE"
	}
	return severityNames[s]
}

func (s Severity) MarshalJSON() ([]byte, error) { return json.Marshal(strings.ToLower(s.String())) }

func parseSeverity(v string) (Severity, error) {
	if strings.EqualFold(v, "none") || strings.EqualFold(v, "never") {
		return never, nil
	}
	for i, n := range severityNames {
		if strings.EqualFold(n, v) {
			return Severity(i), nil
		}
	}
	return 0, fmt.Errorf("unknown severity %q (use info, low, medium, high, critical or none)", v)
}

// Categories group findings in the report.
const (
	CatSecrets   = "Secrets"
	CatDatabase  = "Database & RLS"
	CatAuth      = "Auth & Access control"
	CatTransport = "Transport security"
	CatInjection = "Injection"
	CatLogging   = "Logging & Error handling"
	CatMobile    = "Mobile app"
	CatInfra     = "Infrastructure"
	CatSupply    = "Supply chain"
	CatScale     = "Scalability"
	CatLive      = "Live deployment"
)

// RuleMeta describes one kind of finding. Every rule registers itself in the catalog so it can be
// listed (--list-rules), suppressed by ID, and described in SARIF output.
type RuleMeta struct {
	ID       string   `json:"rule_id"`
	Severity Severity `json:"severity"`
	Category string   `json:"category"`
	Title    string   `json:"title"`
	Fix      string   `json:"fix"`
}

var catalog map[string]*RuleMeta

var ruleIDPattern = regexp.MustCompile(`^(?:[A-Z][A-Z0-9]{1,5}\d{3}|LIVE-[A-Z0-9-]+)$`)

func rule(id string, sev Severity, category, title, fix string) *RuleMeta {
	if catalog == nil {
		catalog = map[string]*RuleMeta{}
	}
	if _, dup := catalog[id]; dup {
		panic("duplicate rule id " + id)
	}
	if !ruleIDPattern.MatchString(id) {
		panic("malformed rule id " + id)
	}
	m := &RuleMeta{ID: id, Severity: sev, Category: category, Title: title, Fix: fix}
	catalog[id] = m
	return m
}

// At creates a finding for this rule at a location.
func (m *RuleMeta) At(file string, line int, snippet string) Finding {
	return Finding{RuleMeta: m, File: file, Line: line, Snippet: cleanSnippet(snippet)}
}

// Finding is one concrete occurrence of a rule.
type Finding struct {
	*RuleMeta
	File    string `json:"file,omitempty"`
	Line    int    `json:"line,omitempty"`
	Snippet string `json:"snippet,omitempty"`
	Detail  string `json:"detail,omitempty"`
	Commit  string `json:"commit,omitempty"`
}

func (f Finding) with(detail string) Finding {
	f.Detail = detail
	return f
}

func (f Finding) location() string {
	loc := f.File
	if loc == "" {
		return ""
	}
	if f.Line > 0 {
		loc = fmt.Sprintf("%s:%d", loc, f.Line)
	}
	if f.Commit != "" {
		loc += " (commit " + f.Commit + ")"
	}
	return loc
}

func cleanSnippet(s string) string {
	s = strings.TrimSpace(strings.ReplaceAll(s, "\t", " "))
	if r := []rune(s); len(r) > 160 {
		s = string(r[:157]) + "..."
	}
	return s
}

func sortFindings(fs []Finding) {
	sort.SliceStable(fs, func(i, j int) bool {
		a, b := fs[i], fs[j]
		if a.Severity != b.Severity {
			return a.Severity > b.Severity
		}
		if a.ID != b.ID {
			return a.ID < b.ID
		}
		if a.File != b.File {
			return a.File < b.File
		}
		return a.Line < b.Line
	})
}

func dedupe(fs []Finding) []Finding {
	seen := make(map[string]bool, len(fs))
	out := fs[:0]
	for _, f := range fs {
		k := fmt.Sprintf("%s|%s|%d|%s|%s", f.ID, f.File, f.Line, f.Commit, f.Detail)
		if seen[k] {
			continue
		}
		seen[k] = true
		out = append(out, f)
	}
	return out
}
