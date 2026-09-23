package main

import (
	"fmt"
	"regexp"
	"strings"
)

var (
	sqlNoRLS = rule("SQL001", Critical, CatDatabase, "Table in an API-exposed schema has Row Level Security disabled",
		"`alter table <t> enable row level security;` and add explicit policies. Without RLS, anyone holding the public anon/publishable key can read and write every row through the Data API.")
	sqlNotForced = rule("SQL002", Info, CatDatabase, "RLS is enabled but not forced",
		"`alter table <t> force row level security;` so the table owner (and migrations running as it) is also subject to policies.")
	sqlDisableRLS = rule("SQL003", Critical, CatDatabase, "Migration disables Row Level Security",
		"Remove the `disable row level security` statement; fix the policy that made it necessary instead.")
	sqlPolicyTrue = rule("SQL010", High, CatDatabase, "RLS policy is always true (`using (true)` / `with check (true)`)",
		"A true policy grants the operation to every role the policy applies to. Scope it to the owner, e.g. `using ((select auth.uid()) = user_id)`, or restrict it with `to authenticated` if the data is genuinely shared.")
	sqlUIDPerRow = rule("SQL011", Medium, CatScale, "RLS policy calls auth.uid()/auth.jwt() once per row",
		"Wrap the call in a sub-select — `(select auth.uid()) = user_id` — so Postgres evaluates it once per query (initPlan) instead of once per row. On large tables this is commonly a 10–100× speed-up.")
	sqlPolicyNoRole = rule("SQL012", Low, CatScale, "RLS policy has no `TO` role, so it also runs for anonymous requests",
		"Add `to authenticated` (or the specific role). Postgres then skips the policy entirely for other roles instead of evaluating it on every anon request.")
	sqlUserMeta = rule("SQL013", High, CatAuth, "Authorization decision uses user-editable metadata",
		"`raw_user_meta_data` / `user_metadata` can be changed by the user themselves via auth.updateUser(). Store roles in `app_metadata` (server-only) or a separate table the user cannot write.")
	sqlPolicyNoIndex = rule("SQL014", Medium, CatScale, "Column used by an RLS policy has no index",
		"Every query against this table filters on the policy column. Add `create index on <table> (<column>);` or each request becomes a sequential scan as the table grows.")
	sqlDefinerPath = rule("SQL020", High, CatDatabase, "SECURITY DEFINER function without a fixed search_path",
		"Add `set search_path = ''` (and schema-qualify every object inside the function). Otherwise a caller can shadow tables/functions and run code with the owner's privileges.")
	sqlDefinerExposed = rule("SQL021", Medium, CatAuth, "SECURITY DEFINER function in an API-exposed schema is callable by clients",
		"Functions in `public` are callable via /rest/v1/rpc and bypass RLS when SECURITY DEFINER. Move it to a private schema, or `revoke execute on function ... from anon, authenticated, public;` and re-check auth.uid() inside it.")
	sqlGrantAnonWrite = rule("SQL030", High, CatAuth, "Write/ALL privileges granted to anon or public",
		"Revoke them. Unauthenticated clients should almost never be able to insert, update, delete or truncate.")
	sqlGrantAnonRead = rule("SQL031", Medium, CatAuth, "SELECT granted to anon or public",
		"Confirm the data is meant to be public and that RLS on the table restricts which rows are visible.")
	sqlDefaultPriv = rule("SQL032", High, CatAuth, "Default privileges grant future tables to anon/public",
		"Every table created later will be exposed automatically. Use `alter default privileges ... revoke ... from anon, public` instead.")
	sqlViewInvoker = rule("SQL040", High, CatDatabase, "View in an API-exposed schema bypasses RLS",
		"Views run with their owner's privileges by default, so they ignore the caller's RLS. Create it `with (security_invoker = true)` (Postgres 15+) or move it out of the exposed schema.")
	sqlMatView = rule("SQL041", Medium, CatDatabase, "Materialized view in an API-exposed schema",
		"Materialized views cannot have RLS. Revoke select from anon/authenticated or move it to a private schema.")
	sqlNoPK = rule("SQL050", Medium, CatScale, "Table has no primary key",
		"Add a primary key. Replication, logical decoding (Realtime), upserts and efficient updates all depend on one.")
	sqlFKNoIndex = rule("SQL051", Medium, CatScale, "Foreign key column has no index",
		"Add an index on the referencing column. Without it, joins are slow and every delete/update on the parent table scans (and locks) the child table.")
)

func init() { projectRules = append(projectRules, sqlRules) }

// stripSQLComments blanks out comments while preserving byte offsets, so line numbers stay exact.
func stripSQLComments(s string) string {
	b := []byte(s)
	inStr := false
	for i := 0; i < len(b); i++ {
		switch {
		case inStr:
			if b[i] == '\'' {
				inStr = false
			}
		case b[i] == '\'':
			inStr = true
		case b[i] == '-' && i+1 < len(b) && b[i+1] == '-':
			for i < len(b) && b[i] != '\n' {
				b[i] = ' '
				i++
			}
		case b[i] == '/' && i+1 < len(b) && b[i+1] == '*':
			for i < len(b) && !(b[i] == '*' && i+1 < len(b) && b[i+1] == '/') {
				if b[i] != '\n' {
					b[i] = ' '
				}
				i++
			}
			if i+1 < len(b) {
				b[i], b[i+1] = ' ', ' '
				i++
			}
		}
	}
	return string(b)
}

func normIdent(s string) string {
	s = strings.ToLower(strings.ReplaceAll(strings.TrimSpace(s), `"`, ""))
	return strings.TrimPrefix(s, "public.")
}

// exposed reports whether a table/view lives in a schema Supabase exposes through the Data API.
func exposed(name string) bool { return !strings.Contains(name, ".") }

var (
	reCreateTable  = regexp.MustCompile(`(?is)\bcreate\s+(?:unlogged\s+)?table\s+(?:if\s+not\s+exists\s+)?([\w."]+)\s*\(`)
	reEnableRLS    = regexp.MustCompile(`(?is)\balter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?([\w."]+)\s+enable\s+row\s+level\s+security`)
	reForceRLS     = regexp.MustCompile(`(?is)\balter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?([\w."]+)\s+force\s+row\s+level\s+security`)
	reDisableRLS   = regexp.MustCompile(`(?is)\balter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?([\w."]+)\s+(?:disable|no\s+force)\s+row\s+level\s+security`)
	rePolicy       = regexp.MustCompile(`(?is)\bcreate\s+policy\s+("[^"]+"|\w+)\s+on\s+([\w."]+)([^;]*);`)
	reAuthCall     = regexp.MustCompile(`(?i)auth\.(?:uid|jwt|role|email)\s*\(\s*\)`)
	reTrue         = regexp.MustCompile(`(?i)(?:using|check)\s*\(\s*true\s*\)`)
	reToRole       = regexp.MustCompile(`(?i)\bto\s+(?:"?\w+"?\s*,\s*)*"?\w+"?\s*(?:using|with|$)`)
	reUserMeta     = regexp.MustCompile(`(?i)raw_user_meta_data|user_metadata`)
	rePolicyCol    = regexp.MustCompile(`(?i)(?:"?(\w+)"?\s*=\s*\(?\s*(?:select\s+)?auth\.uid\(\s*\)|auth\.uid\(\s*\)\s*\)?\s*=\s*"?(\w+)"?)`)
	reFunction     = regexp.MustCompile(`(?is)\bcreate\s+(?:or\s+replace\s+)?function\s+([\w."]+)\s*\(`)
	reDollarTag    = regexp.MustCompile(`\$\w*\$`)
	reRevokeExec   = regexp.MustCompile(`(?is)\brevoke\s+(?:execute|all)\s+on\s+(?:function\s+|all\s+functions\s+in\s+schema\s+)([\w."]+)[^;]*from[^;]*\b(?:anon|public)\b`)
	reGrant        = regexp.MustCompile(`(?is)\bgrant\s+([\w\s,]+?)\s+on\s+(?:table\s+)?(all\s+tables\s+in\s+schema\s+\w+|[\w.",\s]+?)\s+to\s+([\w\s,"]+?)\s*(?:with\s+grant\s+option\s*)?;`)
	reDefaultPriv  = regexp.MustCompile(`(?is)\balter\s+default\s+privileges[^;]*\bgrant\b[^;]*\bto\b[^;]*\b(?:anon|public)\b[^;]*;`)
	reView         = regexp.MustCompile(`(?is)\bcreate\s+(?:or\s+replace\s+)?(materialized\s+)?view\s+(?:if\s+not\s+exists\s+)?([\w."]+)([^;]*?)\bas\b`)
	reViewInvoker  = regexp.MustCompile(`(?is)security_invoker\s*=\s*(?:true|on|1)`)
	reAlterViewInv = regexp.MustCompile(`(?is)\balter\s+view\s+([\w."]+)\s+set\s*\(\s*security_invoker\s*=\s*(?:true|on|1)`)
	reAlterPK      = regexp.MustCompile(`(?is)\balter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?([\w."]+)\s+add\s+(?:constraint\s+[\w"]+\s+)?primary\s+key\s*\(\s*"?(\w+)`)
	reAlterFK      = regexp.MustCompile(`(?is)\balter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?([\w."]+)\s+add\s+(?:constraint\s+[\w"]+\s+)?foreign\s+key\s*\(\s*"?(\w+)`)
	reAlterUnique  = regexp.MustCompile(`(?is)\balter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?([\w."]+)\s+add\s+(?:constraint\s+[\w"]+\s+)?unique\s*\(\s*"?(\w+)`)
	reAddColFK     = regexp.MustCompile(`(?is)\balter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?([\w."]+)\s+add\s+column\s+(?:if\s+not\s+exists\s+)?"?(\w+)"?[^;,]*?\breferences\b`)
	reIndex        = regexp.MustCompile(`(?is)\bcreate\s+(?:unique\s+)?index\s+(?:concurrently\s+)?(?:if\s+not\s+exists\s+)?(?:[\w"]+\s+)?on\s+(?:only\s+)?([\w."]+)\s*(?:using\s+\w+\s*)?\(\s*"?(\w+)`)
	reColFK        = regexp.MustCompile(`(?is)^\s*"?(\w+)"?\s+[^,]*?\breferences\b`)
	reTableFK      = regexp.MustCompile(`(?is)foreign\s+key\s*\(\s*"?(\w+)`)
	reTablePK      = regexp.MustCompile(`(?is)\bprimary\s+key\s*\(\s*"?(\w+)`)
	reTableUnique  = regexp.MustCompile(`(?is)\bunique\s*\(\s*"?(\w+)`)
	reSecDefiner   = regexp.MustCompile(`\bsecurity\s+definer\b`)
	reSetPath      = regexp.MustCompile(`\bset\s+search_path\b`)
	reAnonRole     = regexp.MustCompile(`\b(?:anon|public)\b`)
	reWritePriv    = regexp.MustCompile(`\b(?:all|insert|update|delete|truncate)\b`)
	reColPK        = regexp.MustCompile(`(?is)^\s*"?(\w+)"?\s+[^,]*?\b(?:primary\s+key|unique)\b`)
)

type sqlLoc struct {
	file string
	line int
	text string
}

type sqlTable struct {
	loc    sqlLoc
	hasPK  bool
	partOf bool
}

// matchingParen returns the index of the parenthesis closing the one at open, or -1.
func matchingParen(s string, open int) int {
	depth := 0
	inStr := false
	for i := open; i < len(s); i++ {
		c := s[i]
		if inStr {
			if c == '\'' {
				inStr = false
			}
			continue
		}
		switch c {
		case '\'':
			inStr = true
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				return i
			}
		}
	}
	return -1
}

// splitTopLevel splits a column list on commas that are not nested inside parentheses.
func splitTopLevel(s string) []string {
	var parts []string
	depth, start := 0, 0
	for i, c := range s {
		switch c {
		case '(':
			depth++
		case ')':
			depth--
		case ',':
			if depth == 0 {
				parts = append(parts, s[start:i])
				start = i + 1
			}
		}
	}
	return append(parts, s[start:])
}

func sqlRules(p *Project) []Finding {
	files := p.filesWhere(func(rel, _, ext string) bool {
		if ext != ".sql" {
			return false
		}
		l := strings.ToLower(rel)
		return !strings.Contains(l, "/test") && !strings.HasPrefix(l, "test") && !strings.Contains(l, "seed")
	})
	if len(files) == 0 {
		return nil
	}

	type fileSQL struct{ rel, raw, sql string }
	var all []fileSQL
	supabase := p.Stack["supabase"]
	for _, f := range files {
		raw, err := p.Read(f)
		if err != nil {
			continue
		}
		s := stripSQLComments(raw)
		if reAuthCall.MatchString(s) || strings.Contains(strings.ToLower(s), "row level security") {
			supabase = true
		}
		all = append(all, fileSQL{f, raw, s})
	}

	tables := map[string]*sqlTable{}
	var tableOrder []string
	rlsOn := map[string]bool{}
	forced := map[string]bool{}
	indexed := map[string]bool{} // "table.col" whose leading index column is col
	type fk struct {
		table, col string
		loc        sqlLoc
	}
	var fks []fk
	type policyCol struct {
		table, col string
		loc        sqlLoc
	}
	var policyCols []policyCol
	var out []Finding
	revoked := map[string]bool{}
	invokerViews := map[string]bool{}

	at := func(fs fileSQL, off int) sqlLoc {
		ln := lineAt(fs.raw, off)
		return sqlLoc{fs.rel, ln, lineText(fs.raw, ln)}
	}

	// Pass 1: collect facts across every migration (order-independent).
	for _, fs := range all {
		s := fs.sql
		for _, m := range reCreateTable.FindAllStringSubmatchIndex(s, -1) {
			name := normIdent(s[m[2]:m[3]])
			open := m[1] - 1
			close := matchingParen(s, open)
			if close < 0 {
				continue
			}
			body := s[open+1 : close]
			t := tables[name]
			if t == nil {
				t = &sqlTable{loc: at(fs, m[0])}
				tables[name] = t
				tableOrder = append(tableOrder, name)
			}
			rest := strings.ToLower(s[close:min(len(s), close+80)])
			t.partOf = strings.Contains(rest, "partition of")
			for _, col := range splitTopLevel(body) {
				c := strings.TrimSpace(col)
				lc := strings.ToLower(c)
				if strings.Contains(lc, "primary key") {
					t.hasPK = true
				}
				if mm := reColPK.FindStringSubmatch(c); mm != nil && !strings.HasPrefix(lc, "constraint") &&
					!strings.HasPrefix(lc, "primary") && !strings.HasPrefix(lc, "unique") {
					indexed[name+"."+strings.ToLower(mm[1])] = true
				}
				if mm := reTablePK.FindStringSubmatch(c); mm != nil {
					indexed[name+"."+strings.ToLower(mm[1])] = true
				}
				if mm := reTableUnique.FindStringSubmatch(c); mm != nil {
					indexed[name+"."+strings.ToLower(mm[1])] = true
				}
				if mm := reTableFK.FindStringSubmatch(c); mm != nil {
					fks = append(fks, fk{name, strings.ToLower(mm[1]), at(fs, open+1+strings.Index(body, col))})
				} else if mm := reColFK.FindStringSubmatch(c); mm != nil && !strings.HasPrefix(lc, "constraint") {
					fks = append(fks, fk{name, strings.ToLower(mm[1]), at(fs, open+1+strings.Index(body, col))})
				}
			}
		}
		for _, m := range reEnableRLS.FindAllStringSubmatch(s, -1) {
			rlsOn[normIdent(m[1])] = true
		}
		for _, m := range reForceRLS.FindAllStringSubmatch(s, -1) {
			forced[normIdent(m[1])] = true
		}
		for _, m := range reIndex.FindAllStringSubmatch(s, -1) {
			indexed[normIdent(m[1])+"."+strings.ToLower(m[2])] = true
		}
		for _, m := range reAlterPK.FindAllStringSubmatch(s, -1) {
			if t := tables[normIdent(m[1])]; t != nil {
				t.hasPK = true
			}
			indexed[normIdent(m[1])+"."+strings.ToLower(m[2])] = true
		}
		for _, m := range reAlterUnique.FindAllStringSubmatch(s, -1) {
			indexed[normIdent(m[1])+"."+strings.ToLower(m[2])] = true
		}
		for _, m := range reAlterFK.FindAllStringSubmatchIndex(s, -1) {
			fks = append(fks, fk{normIdent(s[m[2]:m[3]]), strings.ToLower(s[m[4]:m[5]]), at(fs, m[0])})
		}
		for _, m := range reAddColFK.FindAllStringSubmatchIndex(s, -1) {
			fks = append(fks, fk{normIdent(s[m[2]:m[3]]), strings.ToLower(s[m[4]:m[5]]), at(fs, m[0])})
		}
		for _, m := range reRevokeExec.FindAllStringSubmatch(s, -1) {
			revoked[normIdent(m[1])] = true
		}
		for _, m := range reAlterViewInv.FindAllStringSubmatch(s, -1) {
			invokerViews[normIdent(m[1])] = true
		}
	}

	// Pass 2: statement-level findings.
	for _, fs := range all {
		s := fs.sql
		for _, m := range reDisableRLS.FindAllStringSubmatchIndex(s, -1) {
			l := at(fs, m[0])
			out = append(out, sqlDisableRLS.At(l.file, l.line, l.text))
		}
		for _, m := range rePolicy.FindAllStringSubmatchIndex(s, -1) {
			table := normIdent(s[m[4]:m[5]])
			body := s[m[6]:m[7]]
			l := at(fs, m[0])
			name := strings.Trim(s[m[2]:m[3]], `"`)
			detail := fmt.Sprintf("policy %q on %s", name, table)
			if reTrue.MatchString(body) {
				out = append(out, sqlPolicyTrue.At(l.file, l.line, l.text).with(detail))
			}
			if reUserMeta.MatchString(body) {
				out = append(out, sqlUserMeta.At(l.file, l.line, l.text).with(detail))
			}
			for _, cm := range reAuthCall.FindAllStringIndex(body, -1) {
				prefix := strings.ToLower(strings.TrimRight(body[:cm[0]], " \t\r\n("))
				if !strings.HasSuffix(prefix, "select") {
					out = append(out, sqlUIDPerRow.At(l.file, l.line, l.text).with(detail))
					break
				}
			}
			if !reToRole.MatchString(body) {
				out = append(out, sqlPolicyNoRole.At(l.file, l.line, l.text).with(detail))
			}
			for _, pm := range rePolicyCol.FindAllStringSubmatch(body, -1) {
				col := pm[1]
				if col == "" {
					col = pm[2]
				}
				col = strings.ToLower(col)
				if col != "" && col != "select" {
					policyCols = append(policyCols, policyCol{table, col, l})
				}
			}
		}
		for _, m := range reFunction.FindAllStringSubmatchIndex(s, -1) {
			stmt := functionStatement(s, m[0])
			lstmt := strings.ToLower(stmt)
			if !reSecDefiner.MatchString(lstmt) {
				continue
			}
			name := normIdent(s[m[2]:m[3]])
			l := at(fs, m[0])
			if !reSetPath.MatchString(lstmt) {
				out = append(out, sqlDefinerPath.At(l.file, l.line, l.text).with("function "+name))
			}
			if supabase && exposed(name) && !revoked[name] {
				out = append(out, sqlDefinerExposed.At(l.file, l.line, l.text).with("function "+name))
			}
		}
		for _, m := range reGrant.FindAllStringSubmatchIndex(s, -1) {
			privs := strings.ToLower(s[m[2]:m[3]])
			roles := strings.ToLower(s[m[6]:m[7]])
			if !reAnonRole.MatchString(roles) {
				continue
			}
			l := at(fs, m[0])
			target := strings.TrimSpace(s[m[4]:m[5]])
			if reWritePriv.MatchString(privs) {
				out = append(out, sqlGrantAnonWrite.At(l.file, l.line, l.text).with("on "+target))
			} else if strings.Contains(privs, "select") {
				out = append(out, sqlGrantAnonRead.At(l.file, l.line, l.text).with("on "+target))
			}
		}
		for _, m := range reDefaultPriv.FindAllStringIndex(s, -1) {
			l := at(fs, m[0])
			out = append(out, sqlDefaultPriv.At(l.file, l.line, l.text))
		}
		for _, m := range reView.FindAllStringSubmatchIndex(s, -1) {
			name := normIdent(s[m[4]:m[5]])
			if !supabase || !exposed(name) {
				continue
			}
			l := at(fs, m[0])
			if m[2] >= 0 {
				out = append(out, sqlMatView.At(l.file, l.line, l.text).with("view "+name))
			} else if !reViewInvoker.MatchString(s[m[6]:m[7]]) && !invokerViews[name] {
				out = append(out, sqlViewInvoker.At(l.file, l.line, l.text).with("view "+name))
			}
		}
	}

	// Pass 3: table-level findings.
	for _, name := range tableOrder {
		t := tables[name]
		if t.partOf {
			continue
		}
		detail := "table " + name
		if supabase && exposed(name) {
			if !rlsOn[name] {
				out = append(out, sqlNoRLS.At(t.loc.file, t.loc.line, t.loc.text).with(detail))
			} else if !forced[name] {
				out = append(out, sqlNotForced.At(t.loc.file, t.loc.line, t.loc.text).with(detail))
			}
		}
		if !t.hasPK {
			out = append(out, sqlNoPK.At(t.loc.file, t.loc.line, t.loc.text).with(detail))
		}
	}
	for _, f := range fks {
		if !indexed[f.table+"."+f.col] {
			out = append(out, sqlFKNoIndex.At(f.loc.file, f.loc.line, f.loc.text).with(f.table+"."+f.col))
		}
	}
	seenPC := map[string]bool{}
	for _, pc := range policyCols {
		k := pc.table + "." + pc.col
		if indexed[k] || seenPC[k] {
			continue
		}
		seenPC[k] = true
		out = append(out, sqlPolicyNoIndex.At(pc.loc.file, pc.loc.line, pc.loc.text).with(k))
	}
	return out
}

// functionStatement returns a CREATE FUNCTION statement including its dollar-quoted body and the
// attributes that may follow it (SECURITY DEFINER, SET search_path ...).
func functionStatement(s string, start int) string {
	rest := s[start:]
	tag := reDollarTag.FindStringIndex(rest)
	semi := strings.IndexByte(rest, ';')
	if tag == nil || (semi >= 0 && semi < tag[0]) {
		if semi < 0 {
			return rest
		}
		return rest[:semi]
	}
	t := rest[tag[0]:tag[1]]
	closeIdx := strings.Index(rest[tag[1]:], t)
	if closeIdx < 0 {
		return rest
	}
	after := tag[1] + closeIdx + len(t)
	end := strings.IndexByte(rest[after:], ';')
	if end < 0 {
		return rest
	}
	// Keep the header and trailer, drop the body so statements inside it can't confuse matching.
	return rest[:tag[0]] + " " + rest[after:after+end]
}
