package main

import (
	"bufio"
	"os/exec"
	"strconv"
	"strings"
)

// scanHistory streams `git log -p` and runs the secret rules over every added line, so credentials
// that were committed and later deleted are still caught. It streams rather than buffering, so
// memory stays flat even on repositories with hundreds of thousands of commits.
func scanHistory(p *Project, maxCommits int, current []Finding) ([]Finding, int) {
	if !p.IsGit {
		return nil, 0
	}
	args := []string{"-C", p.Root, "log", "--all", "-p", "--no-color", "--no-ext-diff", "--unified=0",
		"--diff-filter=AM", "--format=commit %h"}
	if maxCommits > 0 {
		args = append(args, "-n", strconv.Itoa(maxCommits))
	}
	cmd := exec.Command("git", args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, 0
	}
	if err := cmd.Start(); err != nil {
		return nil, 0
	}
	defer cmd.Wait()

	// A secret still present in the working tree is already reported; report history-only ones.
	inTree := map[string]bool{}
	for _, f := range current {
		if f.Category == CatSecrets {
			inTree[f.ID+"|"+f.File] = true
		}
	}
	seen := map[string]bool{}
	var out []Finding
	commits := 0
	var commit, file string
	skipFile := false
	newLine := 0

	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 256*1024), 8*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "commit "):
			commit = strings.TrimPrefix(line, "commit ")
			commits++
			continue
		case strings.HasPrefix(line, "+++ "):
			file = strings.TrimPrefix(strings.TrimPrefix(line, "+++ "), "b/")
			skipFile = file == "/dev/null" || skipPath(file) || p.ignore.excludesPath(file)
			continue
		case strings.HasPrefix(line, "@@ "):
			// @@ -a,b +c,d @@
			if i := strings.Index(line, "+"); i >= 0 {
				rest := line[i+1:]
				if j := strings.IndexAny(rest, ", "); j >= 0 {
					rest = rest[:j]
				}
				newLine, _ = strconv.Atoi(rest)
			}
			continue
		case strings.HasPrefix(line, "Binary files"):
			continue
		}
		if skipFile || !strings.HasPrefix(line, "+") || strings.HasPrefix(line, "+++") {
			continue
		}
		text := line[1:]
		ln := newLine
		newLine++
		if len(text) > maxLineLen {
			text = text[:maxLineLen]
		}
		lower := strings.ToLower(text)
		for _, r := range secretLineRules {
			base := file[strings.LastIndex(file, "/")+1:]
			if r.Files != nil && !r.Files(file, base, fileExt(file)) {
				continue
			}
			if len(r.Keywords) > 0 && !containsAny(lower, r.Keywords) {
				continue
			}
			loc := r.Pattern.FindStringSubmatchIndex(text)
			if loc == nil || suppressed(text, r.Meta.ID) {
				continue
			}
			match := text[loc[0]:loc[1]]
			meta := r.Meta
			if r.Check != nil {
				groups := make([]string, 0, len(loc)/2)
				for g := 0; g+1 < len(loc); g += 2 {
					if loc[g] >= 0 {
						groups = append(groups, text[loc[g]:loc[g+1]])
					} else {
						groups = append(groups, "")
					}
				}
				if meta = r.Check(match, groups, text); meta == nil {
					continue
				}
			}
			if meta.Severity < Medium || inTree[meta.ID+"|"+file] {
				continue
			}
			key := meta.ID + "|" + file + "|" + match
			if seen[key] {
				continue
			}
			seen[key] = true
			f := secHistory.At(file, ln, redactLine(text, loc))
			f.Commit = commit
			f.Detail = meta.Title
			out = append(out, f)
		}
	}
	return out, commits
}
