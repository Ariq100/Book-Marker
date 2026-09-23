package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// ignoreList holds suppressions from a .deploycheckignore file:
//
//	tools/generated/**          skip these paths entirely
//	SQL012                      turn a rule off everywhere
//	SQL012 supabase/seed/*.sql  turn a rule off for matching paths
type ignoreList struct {
	paths []*regexp.Regexp
	rules map[string][]*regexp.Regexp // rule ID -> path globs (nil slice = everywhere)
	neg   []*regexp.Regexp            // gitignore "!pattern" re-includes (walk mode only)
}

func loadIgnoreFile(root string) (*ignoreList, error) {
	il := &ignoreList{rules: map[string][]*regexp.Regexp{}}
	b, err := os.ReadFile(filepath.Join(root, ".deploycheckignore"))
	if os.IsNotExist(err) {
		return il, nil
	}
	if err != nil {
		return nil, err
	}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if ruleIDPattern.MatchString(fields[0]) {
			if len(fields) == 1 {
				il.rules[fields[0]] = nil
			} else {
				for _, g := range fields[1:] {
					il.rules[fields[0]] = append(il.rules[fields[0]], globToRegexp(g))
				}
				if il.rules[fields[0]] == nil {
					il.rules[fields[0]] = []*regexp.Regexp{}
				}
			}
			continue
		}
		il.paths = append(il.paths, globToRegexp(line))
	}
	return il, nil
}

func parseGitignore(s string) *ignoreList {
	il := &ignoreList{rules: map[string][]*regexp.Regexp{}}
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "!") {
			il.neg = append(il.neg, globToRegexp(line[1:]))
			continue
		}
		il.paths = append(il.paths, globToRegexp(line))
	}
	return il
}

func (il *ignoreList) excludesPath(rel string) bool {
	if il == nil {
		return false
	}
	for _, re := range il.neg {
		if re.MatchString(rel) {
			return false
		}
	}
	for _, re := range il.paths {
		if re.MatchString(rel) {
			return true
		}
	}
	return false
}

func (il *ignoreList) suppresses(f Finding) bool {
	if il == nil {
		return false
	}
	globs, ok := il.rules[f.ID]
	if !ok {
		return false
	}
	if globs == nil || len(globs) == 0 && f.File == "" {
		return true
	}
	for _, re := range globs {
		if re.MatchString(f.File) {
			return true
		}
	}
	return false
}

// globToRegexp supports *, ?, ** and gitignore-style anchoring: a pattern without a slash matches
// at any depth; a trailing slash matches a directory and everything below it.
func globToRegexp(g string) *regexp.Regexp {
	g = filepath.ToSlash(strings.TrimSpace(g))
	dir := strings.HasSuffix(g, "/")
	g = strings.TrimSuffix(g, "/")
	anchored := strings.HasPrefix(g, "/") || strings.Contains(g, "/")
	g = strings.TrimPrefix(g, "/")
	var b strings.Builder
	b.WriteString("^")
	if !anchored {
		b.WriteString("(?:.*/)?")
	}
	for i := 0; i < len(g); i++ {
		c := g[i]
		switch {
		case c == '*' && i+1 < len(g) && g[i+1] == '*':
			i++
			if i+1 < len(g) && g[i+1] == '/' {
				i++
				b.WriteString("(?:.*/)?")
			} else {
				b.WriteString(".*")
			}
		case c == '*':
			b.WriteString("[^/]*")
		case c == '?':
			b.WriteString("[^/]")
		default:
			b.WriteString(regexp.QuoteMeta(string(c)))
		}
	}
	// Matching a directory name also matches everything inside it.
	if dir {
		b.WriteString("/.*$")
	} else {
		b.WriteString("(?:/.*)?$")
	}
	return regexp.MustCompile(b.String())
}
