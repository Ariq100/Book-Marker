package main

import (
	"encoding/json"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
)

var (
	dkrRoot = rule("DKR001", High, CatInfra, "Container runs as root",
		"Add a non-root `USER` (e.g. `USER 10001`) after installing packages. A compromised process in a root container is one kernel bug away from the host.")
	dkrLatest = rule("DKR002", Medium, CatInfra, "Base image is unpinned (:latest or no tag)",
		"Pin a version tag and ideally a digest (`image:1.2.3@sha256:...`) so builds are reproducible and cannot silently pull a compromised image.")
	dkrAddURL = rule("DKR003", Medium, CatInfra, "ADD downloads a remote URL",
		"Use RUN curl with checksum verification, or COPY a vetted artifact.")
	dkrEnvSecret = rule("DKR004", High, CatInfra, "Secret baked into the image via ENV/ARG",
		"Image layers are readable by anyone who can pull the image. Use BuildKit secrets (`--mount=type=secret`) or inject at runtime.")
	dkrPipeShell = rule("DKR005", Medium, CatSupply, "Remote script piped straight into a shell",
		"Download, verify the checksum/signature, then execute.")
	dkrHealth = rule("DKR006", Low, CatScale, "No HEALTHCHECK in Dockerfile",
		"Add a HEALTHCHECK (or orchestrator probes) so load balancers stop routing to dead instances.")
	dkrIgnore = rule("DKR007", Medium, CatInfra, "No .dockerignore next to Dockerfile",
		"Without it, `.git`, `.env` and local secrets are copied into the build context and often into the image.")

	cmpPrivileged = rule("CMP001", High, CatInfra, "Compose service runs privileged or on the host network",
		"Remove `privileged: true` / `network_mode: host`; grant only the specific capabilities needed.")
	cmpDBPort = rule("CMP002", High, CatInfra, "Database/cache port published on all interfaces",
		"Bind to 127.0.0.1 (`127.0.0.1:5432:5432`) or do not publish it at all; let services talk over the internal network.")

	k8sPrivileged = rule("K8S001", Critical, CatInfra, "Privileged container or host namespace access",
		"Remove privileged / hostNetwork / hostPID / hostIPC. These give the pod control of the node.")
	k8sLimits = rule("K8S002", High, CatScale, "Workload has no CPU/memory requests and limits",
		"Set resources.requests and resources.limits. Without them the scheduler cannot bin-pack, autoscalers cannot compute utilization, and one pod can starve the node.")
	k8sReady = rule("K8S003", Medium, CatScale, "Workload has no readinessProbe",
		"Add a readinessProbe so traffic only reaches pods that are ready — essential for zero-downtime rolling deploys.")
	k8sLive = rule("K8S004", Low, CatScale, "Workload has no livenessProbe",
		"Add a livenessProbe so hung processes are restarted automatically.")
	k8sNonRoot = rule("K8S005", Medium, CatInfra, "Pod does not enforce runAsNonRoot",
		"Set securityContext.runAsNonRoot: true and a numeric runAsUser.")
	k8sPrivEsc = rule("K8S006", Medium, CatInfra, "allowPrivilegeEscalation not disabled",
		"Set securityContext.allowPrivilegeEscalation: false and drop ALL capabilities.")
	k8sImage = rule("K8S007", Medium, CatInfra, "Container image is unpinned (:latest or no tag)",
		"Pin a version tag or digest. `:latest` makes rollbacks impossible and different pods run different code.")
	k8sReplicas = rule("K8S008", Low, CatScale, "Deployment runs a single replica",
		"Run at least 2 replicas (plus a PodDisruptionBudget) so a node drain or crash does not cause downtime.")
	k8sROFS = rule("K8S009", Low, CatInfra, "Root filesystem is writable",
		"Set securityContext.readOnlyRootFilesystem: true and mount writable emptyDirs only where needed.")
	k8sEnvSecret = rule("K8S010", High, CatSecrets, "Secret value inlined in a Kubernetes manifest",
		"Reference a Secret via valueFrom.secretKeyRef (ideally synced from a secret manager) instead of a literal value.")
	k8sHPA = rule("K8S020", Medium, CatScale, "No HorizontalPodAutoscaler for any Deployment",
		"Add an HPA (or KEDA) so capacity follows load instead of being fixed.")
	k8sPDB = rule("K8S021", Low, CatScale, "No PodDisruptionBudget",
		"Add a PDB so voluntary disruptions (node upgrades) never take every replica down at once.")
	k8sNetPol = rule("K8S022", Medium, CatInfra, "No NetworkPolicy",
		"Default-deny ingress/egress per namespace and allow only required flows, limiting lateral movement after a breach.")

	tfOpen = rule("TF001", High, CatInfra, "Security group open to the whole internet (0.0.0.0/0)",
		"Restrict ingress to known CIDRs or put the service behind a load balancer. Only 80/443 on a public LB should be world-open.")
	tfPublicBucket = rule("TF002", High, CatInfra, "Storage bucket is public",
		"Use private ACLs, block public access, and serve public files through a CDN with signed URLs if needed.")
	tfUnencrypted = rule("TF003", High, CatInfra, "Encryption at rest disabled",
		"Enable encryption (KMS-managed keys) for databases, volumes and buckets.")
	tfPublicDB = rule("TF004", High, CatInfra, "Database is publicly accessible",
		"Set publicly_accessible = false and reach it from private subnets / a bastion / VPN.")
	tfBackups = rule("TF005", Medium, CatInfra, "Automated backups disabled",
		"Set backup_retention_period to at least 7 days and test restores.")
	tfDeletion = rule("TF006", Low, CatInfra, "Deletion protection disabled / no final snapshot",
		"Enable deletion_protection and final snapshots on production data stores.")
	tfSingleAZ = rule("TF007", Low, CatScale, "Database is single-AZ",
		"Enable multi_az for production so a zone outage does not take the database down.")

	ngxAutoindex = rule("NGX001", Medium, CatInfra, "Directory listing enabled",
		"Set `autoindex off;`.")
	ngxTokens = rule("NGX002", Low, CatInfra, "Server version disclosed",
		"Set `server_tokens off;` so attackers cannot fingerprint exact versions.")

	ghaPRTarget = rule("GHA001", High, CatSupply, "Workflow uses pull_request_target",
		"pull_request_target runs with secrets and write access on code from forks. Use pull_request, or never check out/run the PR's code in that job.")
	ghaInjection = rule("GHA002", High, CatSupply, "Untrusted GitHub event data interpolated into a script",
		"Pass the value through an env var (`env: TITLE: ${{ github.event.issue.title }}`) and reference \"$TITLE\" in the script.")
	ghaUnpinned = rule("GHA003", Medium, CatSupply, "Third-party action pinned to a branch",
		"Pin actions to a full commit SHA. Branches (and tags) can be moved to malicious code.")
	ghaPerms = rule("GHA004", Medium, CatSupply, "Workflow does not restrict GITHUB_TOKEN permissions",
		"Add a top-level `permissions: contents: read` and grant more per job only where needed.")

	supLockfile = rule("SUP001", Medium, CatSupply, "Dependency manifest without a lockfile",
		"Commit the lockfile and install with `npm ci` / `pip install --require-hashes` so production installs exactly what you tested.")
	supLooseDep = rule("SUP002", Medium, CatSupply, "Dependency version is `*`, `latest` or a git branch",
		"Pin to a semver range at minimum and rely on the lockfile; review upgrades through Dependabot/Renovate.")
	supUnpinnedPy = rule("SUP003", Low, CatSupply, "Python requirements are not pinned",
		"Pin with `==` (pip-tools / uv / poetry lock) so deploys are reproducible.")
	supDependabot = rule("SUP005", Low, CatSupply, "No automated dependency update configuration",
		"Add .github/dependabot.yml or Renovate so security patches are proposed automatically.")
)

var k8sKind = regexp.MustCompile(`(?m)^kind:\s*(Deployment|StatefulSet|DaemonSet|Pod|Job|CronJob|ReplicaSet)\s*$`)

func init() {
	lineRules = append(lineRules,
		&LineRule{Meta: tfOpen, Files: exts(".tf"), SkipComments: true, Keywords: []string{"0.0.0.0/0", "::/0"},
			Pattern: regexp.MustCompile(`(?:cidr_blocks|cidr_ipv4|ipv6_cidr_blocks|source_ranges|cidr_ipv6)\s*=\s*\[?[^\]\n]*"(?:0\.0\.0\.0/0|::/0)"`)},
		&LineRule{Meta: tfPublicBucket, Files: exts(".tf"), SkipComments: true, Keywords: []string{"public-read", "block_public", "allusers"},
			Pattern: regexp.MustCompile(`acl\s*=\s*"public-read(?:-write)?"|block_public_(?:acls|policy)\s*=\s*false|"allUsers"|"allAuthenticatedUsers"`)},
		&LineRule{Meta: tfUnencrypted, Files: exts(".tf"), SkipComments: true, Keywords: []string{"encrypt"},
			Pattern: regexp.MustCompile(`\b(?:storage_)?encrypted\s*=\s*false|enable_encryption\s*=\s*false`)},
		&LineRule{Meta: tfPublicDB, Files: exts(".tf"), SkipComments: true, Keywords: []string{"publicly_accessible"},
			Pattern: regexp.MustCompile(`publicly_accessible\s*=\s*true`)},
		&LineRule{Meta: tfBackups, Files: exts(".tf"), SkipComments: true, Keywords: []string{"backup_retention_period"},
			Pattern: regexp.MustCompile(`backup_retention_period\s*=\s*0\b`)},
		&LineRule{Meta: tfDeletion, Files: exts(".tf"), SkipComments: true, Keywords: []string{"deletion_protection", "skip_final_snapshot"},
			Pattern: regexp.MustCompile(`deletion_protection\s*=\s*false|skip_final_snapshot\s*=\s*true`)},
		&LineRule{Meta: tfSingleAZ, Files: exts(".tf"), SkipComments: true, Keywords: []string{"multi_az"},
			Pattern: regexp.MustCompile(`multi_az\s*=\s*false`)},
		&LineRule{Meta: ngxAutoindex, Files: exts(".conf"), SkipComments: true, Keywords: []string{"autoindex"},
			Pattern: regexp.MustCompile(`\bautoindex\s+on\b`)},
		&LineRule{Meta: ngxTokens, Files: exts(".conf"), SkipComments: true, Keywords: []string{"server_tokens"},
			Pattern: regexp.MustCompile(`\bserver_tokens\s+on\b`)},
		&LineRule{Meta: dkrPipeShell, Files: either(exts(".sh", ".bash", ".yml", ".yaml", ".ps1"), func(_, b, _ string) bool { return isDockerfile(b) || b == "Makefile" }),
			SkipComments: true, Keywords: []string{"curl", "wget", "iwr", "invoke-webrequest"},
			Pattern: regexp.MustCompile(`(?i)(?:curl|wget|iwr|invoke-webrequest)\b[^|\n]*\|\s*(?:sudo\s+)?(?:ba|z)?sh\b|(?:curl|wget)\b[^|\n]*\|\s*iex\b`)},
	)
	fileRules = append(fileRules,
		&FileRule{Files: func(_, b, _ string) bool { return isDockerfile(b) }, Check: dockerfileRule},
		&FileRule{Files: func(_, b, _ string) bool {
			return strings.HasPrefix(b, "docker-compose") || strings.HasPrefix(b, "compose.") || strings.HasPrefix(b, "compose-")
		}, Check: composeRule},
		&FileRule{Files: exts(".yaml", ".yml"), Check: k8sRule},
		&FileRule{Files: func(rel, _, ext string) bool {
			return strings.HasPrefix(rel, ".github/workflows/") && (ext == ".yml" || ext == ".yaml")
		}, Check: workflowRule},
		&FileRule{Files: func(_, b, _ string) bool { return b == "package.json" }, Check: packageJSONRule},
		&FileRule{Files: func(_, b, _ string) bool { return b == "requirements.txt" }, Check: requirementsRule},
	)
	projectRules = append(projectRules, lockfileRule, k8sProjectRule, dockerignoreRule, dependabotRule)
}

var (
	reFrom     = regexp.MustCompile(`(?im)^\s*FROM\s+(?:--platform=\S+\s+)?(\S+)(?:\s+AS\s+(\S+))?`)
	reUser     = regexp.MustCompile(`(?im)^\s*USER\s+(\S+)`)
	reAddURL   = regexp.MustCompile(`(?im)^\s*ADD\s+(?:--\S+\s+)*https?://`)
	reEnvSec   = regexp.MustCompile(`(?im)^\s*(?:ENV|ARG)\s+\w*(?:PASSWORD|PASSWD|SECRET|TOKEN|API_KEY|APIKEY|PRIVATE_KEY|ACCESS_KEY)\w*\s*[= ]\s*\S+`)
	reHealth   = regexp.MustCompile(`(?im)^\s*HEALTHCHECK\s`)
	reEnvEmpty = regexp.MustCompile(`=\s*(?:""|''|\$\{?\w+\}?)?\s*$`)
)

func imageUnpinned(img string) bool {
	if img == "scratch" || strings.Contains(img, "@sha256:") || strings.HasPrefix(img, "$") {
		return false
	}
	name := img[strings.LastIndex(img, "/")+1:]
	return !strings.Contains(name, ":") || strings.HasSuffix(name, ":latest")
}

func dockerfileRule(_ *Project, rel, content string) []Finding {
	var out []Finding
	stages := map[string]bool{}
	for _, m := range reFrom.FindAllStringSubmatchIndex(content, -1) {
		img := content[m[2]:m[3]]
		if m[4] >= 0 {
			stages[strings.ToLower(content[m[4]:m[5]])] = true
		}
		if stages[strings.ToLower(img)] {
			continue
		}
		if imageUnpinned(img) {
			ln := lineAt(content, m[0])
			out = append(out, dkrLatest.At(rel, ln, lineText(content, ln)))
		}
	}
	users := reUser.FindAllStringSubmatchIndex(content, -1)
	if len(users) == 0 {
		out = append(out, dkrRoot.At(rel, 0, "").with("no USER instruction"))
	} else {
		last := users[len(users)-1]
		u := strings.ToLower(content[last[2]:last[3]])
		if u == "root" || u == "0" || strings.HasPrefix(u, "0:") || strings.HasPrefix(u, "root:") {
			ln := lineAt(content, last[0])
			out = append(out, dkrRoot.At(rel, ln, lineText(content, ln)))
		}
	}
	for _, m := range reAddURL.FindAllStringIndex(content, -1) {
		ln := lineAt(content, m[0])
		out = append(out, dkrAddURL.At(rel, ln, lineText(content, ln)))
	}
	for _, m := range reEnvSec.FindAllStringIndex(content, -1) {
		ln := lineAt(content, m[0])
		text := lineText(content, ln)
		if reEnvEmpty.MatchString(text) || strings.HasPrefix(strings.ToUpper(strings.TrimSpace(text)), "ARG") && !strings.Contains(text, "=") {
			continue
		}
		out = append(out, dkrEnvSecret.At(rel, ln, redactAfterEquals(text)))
	}
	if !reHealth.MatchString(content) {
		out = append(out, dkrHealth.At(rel, 0, ""))
	}
	return out
}

func redactAfterEquals(s string) string {
	if i := strings.IndexAny(s, "= "); i >= 0 && i+1 < len(s) {
		if j := strings.LastIndexAny(s, "= "); j > 0 {
			return s[:j+1] + "[REDACTED]"
		}
	}
	return s
}

var (
	reCmpPriv = regexp.MustCompile(`(?m)^\s*(?:privileged:\s*true|network_mode:\s*["']?host)`)
	reCmpPort = regexp.MustCompile(`(?m)^\s*-\s*["']?(?:0\.0\.0\.0:)?(\d+):(5432|6543|3306|6379|27017|9200|11211|5672|9042|8086|26257)(?:/tcp)?["']?\s*$`)
)

func composeRule(_ *Project, rel, content string) []Finding {
	var out []Finding
	for _, m := range reCmpPriv.FindAllStringIndex(content, -1) {
		ln := lineAt(content, m[0])
		out = append(out, cmpPrivileged.At(rel, ln, lineText(content, ln)))
	}
	for _, m := range reCmpPort.FindAllStringIndex(content, -1) {
		ln := lineAt(content, m[0])
		out = append(out, cmpDBPort.At(rel, ln, lineText(content, ln)))
	}
	return out
}

var (
	reK8sPriv      = regexp.MustCompile(`(?m)^\s*(?:privileged|hostNetwork|hostPID|hostIPC):\s*true\b`)
	reK8sImage     = regexp.MustCompile(`(?m)^\s*-?\s*image:\s*["']?([^\s"'#]+)`)
	reK8sReplicas1 = regexp.MustCompile(`(?m)^\s*replicas:\s*1\s*$`)
	reYAMLDocSep   = regexp.MustCompile(`(?m)^---[ \t]*$`)
	reRunAsNonRoot = regexp.MustCompile(`runAsNonRoot:\s*true`)
	reNoPrivEsc    = regexp.MustCompile(`allowPrivilegeEscalation:\s*false`)
	reROFS         = regexp.MustCompile(`readOnlyRootFilesystem:\s*true`)
	reK8sEnvSecret = regexp.MustCompile(`(?m)^\s*-\s*name:\s*["']?\w*(?:PASSWORD|SECRET|TOKEN|API_KEY|APIKEY|PRIVATE_KEY|ACCESS_KEY)\w*["']?\s*\n\s*value:\s*["']?[^\s"'$]{4,}`)
)

func k8sRule(_ *Project, rel, content string) []Finding {
	if !k8sKind.MatchString(content) {
		return nil
	}
	var out []Finding
	starts := []int{0}
	for _, m := range reYAMLDocSep.FindAllStringIndex(content, -1) {
		starts = append(starts, m[1])
	}
	for di, base := range starts {
		end := len(content)
		if di+1 < len(starts) {
			end = starts[di+1]
		}
		doc := content[base:end]
		km := k8sKind.FindStringSubmatch(doc)
		if km == nil {
			continue
		}
		kind := km[1]
		first := lineAt(content, base+k8sKind.FindStringIndex(doc)[0])
		at := func(m *RuleMeta, idx int) Finding {
			ln := first
			if idx >= 0 {
				ln = lineAt(content, base+idx)
			}
			return m.At(rel, ln, lineText(content, ln)).with(kind)
		}
		for _, m := range reK8sPriv.FindAllStringIndex(doc, -1) {
			out = append(out, at(k8sPrivileged, m[0]))
		}
		if !strings.Contains(doc, "limits:") || !strings.Contains(doc, "requests:") {
			out = append(out, at(k8sLimits, -1))
		}
		if kind != "Job" && kind != "CronJob" {
			if !strings.Contains(doc, "readinessProbe:") {
				out = append(out, at(k8sReady, -1))
			}
			if !strings.Contains(doc, "livenessProbe:") {
				out = append(out, at(k8sLive, -1))
			}
		}
		if !reRunAsNonRoot.MatchString(doc) {
			out = append(out, at(k8sNonRoot, -1))
		}
		if !reNoPrivEsc.MatchString(doc) {
			out = append(out, at(k8sPrivEsc, -1))
		}
		if !reROFS.MatchString(doc) {
			out = append(out, at(k8sROFS, -1))
		}
		for _, m := range reK8sImage.FindAllStringSubmatchIndex(doc, -1) {
			if imageUnpinned(doc[m[2]:m[3]]) {
				out = append(out, at(k8sImage, m[0]))
			}
		}
		if kind == "Deployment" || kind == "StatefulSet" {
			if m := reK8sReplicas1.FindStringIndex(doc); m != nil {
				out = append(out, at(k8sReplicas, m[0]))
			}
		}
		for _, m := range reK8sEnvSecret.FindAllStringIndex(doc, -1) {
			f := at(k8sEnvSecret, m[0])
			f.Snippet = "[REDACTED]"
			out = append(out, f)
		}
	}
	return out
}

func k8sProjectRule(p *Project) []Finding {
	if !p.Stack["kubernetes"] {
		return nil
	}
	var deploy, hpa, pdb, netpol bool
	for _, f := range p.filesWhere(exts(".yaml", ".yml")) {
		s, err := p.Read(f)
		if err != nil {
			continue
		}
		deploy = deploy || strings.Contains(s, "kind: Deployment") || strings.Contains(s, "kind: StatefulSet")
		hpa = hpa || strings.Contains(s, "kind: HorizontalPodAutoscaler") || strings.Contains(s, "kind: ScaledObject")
		pdb = pdb || strings.Contains(s, "kind: PodDisruptionBudget")
		netpol = netpol || strings.Contains(s, "kind: NetworkPolicy") || strings.Contains(s, "kind: CiliumNetworkPolicy")
	}
	var out []Finding
	if deploy && !hpa {
		out = append(out, k8sHPA.At("", 0, ""))
	}
	if deploy && !pdb {
		out = append(out, k8sPDB.At("", 0, ""))
	}
	if deploy && !netpol {
		out = append(out, k8sNetPol.At("", 0, ""))
	}
	return out
}

func dockerignoreRule(p *Project) []Finding {
	var out []Finding
	for _, f := range p.filesWhere(func(_, b, _ string) bool { return isDockerfile(b) }) {
		dir := path.Dir(f)
		ign := ".dockerignore"
		if dir != "." {
			ign = dir + "/.dockerignore"
		}
		if !p.has(ign) && !p.has(".dockerignore") {
			out = append(out, dkrIgnore.At(f, 0, ""))
		}
	}
	return out
}

var (
	reGHAInject   = regexp.MustCompile(`\$\{\{\s*github\.(?:event\.(?:issue|pull_request|comment|review|review_comment|discussion|head_commit|commits|pages)[^}]*\.(?:title|body|message|name|label|ref|email)|head_ref)[^}]*\}\}`)
	reGHAUses     = regexp.MustCompile(`(?m)^\s*-?\s*uses:\s*["']?([\w.-]+/[\w./-]+)@([\w./-]+)`)
	reGHAPerms    = regexp.MustCompile(`(?m)^permissions:`)
	reGHARunStart = regexp.MustCompile(`^\s*-?\s*(?:run|script):`)
)

func workflowRule(_ *Project, rel, content string) []Finding {
	var out []Finding
	lines := strings.Split(content, "\n")
	inRun, runIndent := false, 0
	for i, line := range lines {
		indent := len(line) - len(strings.TrimLeft(line, " "))
		if reGHARunStart.MatchString(line) {
			inRun, runIndent = true, indent
		} else if inRun && strings.TrimSpace(line) != "" && indent <= runIndent {
			inRun = false
		}
		if strings.Contains(line, "pull_request_target") && !isCommentLine(line) {
			out = append(out, ghaPRTarget.At(rel, i+1, line))
		}
		if inRun && reGHAInject.MatchString(line) {
			out = append(out, ghaInjection.At(rel, i+1, line))
		}
		if m := reGHAUses.FindStringSubmatch(line); m != nil {
			ref := m[2]
			owner := strings.SplitN(m[1], "/", 2)[0]
			if (ref == "main" || ref == "master" || ref == "latest" || ref == "dev" || ref == "develop") && owner != "actions" {
				out = append(out, ghaUnpinned.At(rel, i+1, line))
			}
		}
	}
	if !reGHAPerms.MatchString(content) {
		out = append(out, ghaPerms.At(rel, 0, ""))
	}
	return out
}

func packageJSONRule(_ *Project, rel, content string) []Finding {
	var pkg map[string]json.RawMessage
	if json.Unmarshal([]byte(content), &pkg) != nil {
		return nil
	}
	var out []Finding
	for _, sec := range []string{"dependencies", "devDependencies", "optionalDependencies"} {
		var deps map[string]string
		if json.Unmarshal(pkg[sec], &deps) != nil {
			continue
		}
		for name, ver := range deps {
			v := strings.TrimSpace(ver)
			if v == "*" || v == "latest" || v == "" || v == "x" || strings.HasPrefix(v, "git") ||
				strings.HasPrefix(v, "github:") || (strings.HasPrefix(v, "http") && !strings.Contains(v, "#")) {
				ln := lineAt(content, strings.Index(content, `"`+name+`"`))
				out = append(out, supLooseDep.At(rel, ln, lineText(content, ln)))
			}
		}
	}
	return out
}

func requirementsRule(_ *Project, rel, content string) []Finding {
	loose := 0
	first := 0
	for i, line := range strings.Split(content, "\n") {
		l := strings.TrimSpace(line)
		if l == "" || strings.HasPrefix(l, "#") || strings.HasPrefix(l, "-") {
			continue
		}
		if !strings.Contains(l, "==") && !strings.Contains(l, "@ ") {
			loose++
			if first == 0 {
				first = i + 1
			}
		}
	}
	if loose == 0 {
		return nil
	}
	return []Finding{supUnpinnedPy.At(rel, first, lineText(content, first)).with(itoa(loose) + " unpinned requirement(s)")}
}

func lockfileRule(p *Project) []Finding {
	var out []Finding
	lockNames := []string{"package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "npm-shrinkwrap.json"}
	for _, f := range p.Files {
		if path.Base(f) != "package.json" {
			continue
		}
		dir := path.Dir(f)
		found := false
		// Lockfiles are excluded from scanning, so check the disk directly (monorepos keep one at the root).
		for _, d := range []string{dir, "."} {
			for _, ln := range lockNames {
				if fileExists(p, path.Join(d, ln)) {
					found = true
				}
			}
		}
		if !found {
			out = append(out, supLockfile.At(f, 0, ""))
		}
	}
	return out
}

func dependabotRule(p *Project) []Finding {
	if !p.IsGit {
		return nil
	}
	manifests := p.Stack["node"] || p.Stack["python"] || p.Stack["go"] || p.Stack["docker"] || p.Stack["ios"] || p.Stack["android"]
	if !manifests {
		return nil
	}
	for _, f := range []string{".github/dependabot.yml", ".github/dependabot.yaml", "renovate.json", ".github/renovate.json", "renovate.json5", ".renovaterc", ".renovaterc.json"} {
		if p.has(f) {
			return nil
		}
	}
	return []Finding{supDependabot.At("", 0, "")}
}

func fileExists(p *Project, rel string) bool {
	info, err := os.Stat(filepath.Join(p.Root, filepath.FromSlash(rel)))
	return err == nil && info.Mode().IsRegular()
}
