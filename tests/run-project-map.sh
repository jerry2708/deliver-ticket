#!/bin/bash
# project-map-stale.sh: only A/D/R (and manifest changes) under a section's watch globs make it stale; M is ignored.
# Usage: tests/run-project-map.sh <new scratch dir>. Never deletes anything.
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
R=$S/repo; [ -e "$R" ] && { echo "scratch dir already used: $S" >&2; exit 2; }
mkdir -p "$R/apps/web/src" "$R/apps/agent/src" "$R/docs" && cd "$R" && git init -q -b main
git config user.email t@t; git config user.name t
echo '{"name":"web"}' > apps/web/package.json; echo 'a' > apps/web/src/a.ts; echo 'b' > apps/agent/src/b.ts; seq 1 30 > docs/d.md
echo '{"name":"root"}' > package.json; echo 'lock' > pnpm-lock.yaml
git add -A && git commit -q -m base
BASE=$(git rev-parse --short=10 HEAD)
P=$S/project.md
write_md() { cat > "$P" <<M
# Project map - test
## Web source
checked: $BASE · 2026-01-01 · watch: apps/web/src/**
stale: no
- web src (apps/web/src)
## Agent source
checked: $BASE · 2026-01-01 · watch: apps/agent/src/**
- agent src (apps/agent/src)
## Docs
checked: $BASE · 2026-01-01 · watch: docs/
- docs
## Knowledge sources
- CLAUDE.md (no checked line: never evaluated)
M
}
pass=0; fail=0
ck() { local want=$1 label=$2; shift 2; local out; out=$("$SK/scripts/project-map-stale.sh" "$@" 2>&1); local rc=$?
  if echo "$out" | grep -q -e "$want"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $label: want /$want/"; echo "$out" | sed 's/^/   /'; fi; LAST=$out; LASTRC=$rc; }
eq() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
G=(--repo "$R" --ref main)

echo "# nothing changed -> all fresh, rc 0"
write_md; ck '^fresh Web source' nochange check "$P" "${G[@]}"; eq "$LASTRC" 0 "rc nochange"

echo "# modified-only files are ignored (apps/web/src/a.ts, apps/agent/src/b.ts, docs/d.md)"
echo 'a2' >> apps/web/src/a.ts; echo 'b2' >> apps/agent/src/b.ts; echo 'd2' >> docs/d.md
git commit -qam "modify only"
ck '^fresh Web source' M-web check "$P" "${G[@]}"; ck '^fresh Agent source' M-agent check "$P" "${G[@]}"; ck '^fresh Docs' M-docs check "$P" "${G[@]}"; eq "$LASTRC" 0 "rc M only"

echo "# A under watch -> stale; A outside watch -> other sections stay fresh"
echo n > apps/web/src/new.ts; git add -A; git commit -qm "add web file"
ck '^stale Web source :: A apps/web/src/new.ts' A-web check "$P" "${G[@]}"; ck '^fresh Agent source' A-web-agent-fresh check "$P" "${G[@]}"; eq "$LASTRC" 1 "rc A"

echo "# D under watch"
git rm -q apps/agent/src/b.ts; git commit -qm "delete agent file"
ck '^stale Agent source :: D apps/agent/src/b.ts' D-agent check "$P" "${G[@]}"

echo "# R: rename into/out of a watched dir"
git mv docs/d.md apps/web/src/d.md; git commit -qm "rename docs->web"
ck '^stale Docs :: R ' R-docs-old check "$P" "${G[@]}"

echo "# check is read-only; apply advances fresh sections and marks stale ones; sha of stale ones is kept"
before=$(cat "$P")
"$SK/scripts/project-map-stale.sh" check "$P" "${G[@]}" >/dev/null; eq "$(cat "$P")" "$before" "check must not write"
HEAD1=$(git rev-parse --short=10 HEAD)
git checkout -q -b scratch-edit; git checkout -q main
# a fourth section that is fresh
cat >> "$P" <<M
## Root files
checked: $BASE · 2026-01-01 · watch: LICENSE
M
"$SK/scripts/project-map-stale.sh" apply "$P" "${G[@]}" >/dev/null
grep -q "^checked: $HEAD1 .* watch: LICENSE" "$P" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL apply did not advance fresh section"; grep -n "Root files" -A2 "$P"; }
grep -q "^checked: $BASE .* apps/web/src/\*\*" "$P" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL apply moved the sha of a stale section"; }
grep -q "^stale: yes (. apps/web/src/" "$P" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL apply did not mark stale"; }

echo "# lazy rescan: stays stale on every later run until mark-checked; then fresh"
"$SK/scripts/project-map-stale.sh" apply "$P" "${G[@]}" >/dev/null
ck '^stale Web source' stays-stale check "$P" "${G[@]}"
ck 'marked checked' mark mark-checked "$P" "${G[@]}" "Web source"
ck '^fresh Web source' fresh-after-mark check "$P" "${G[@]}"
grep -q "^stale: no" "$P" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL stale: no missing after mark-checked"; }

echo "# profile rules (config-files, json-keys, lockfiles, workspace-files, app-roots)"
HEAD1=$(git rev-parse --short=10 HEAD)
mk() { printf '## %s\nchecked: %s · 2026-01-01 · watch: %s\n' "$1" "$HEAD1" "$2" > "$P"; }
mk "Web package" "apps/web/package.json"
echo '{"name":"web","dependencies":{"x":"1"}}' > apps/web/package.json; git commit -qam "dependency added"
ck '^fresh Web package' dep-add-is-nothing check "$P" "${G[@]}"; eq "$LASTRC" 0 "rc dep add"
echo '{"name":"web","dependencies":{"x":"1"},"scripts":{"test":"vitest"}}' > apps/web/package.json; git commit -qam "scripts changed"
ck '^stale Web package :: M apps/web/package.json (scripts changed)' scripts-change check "$P" "${G[@]}"
echo "# a modified lockfile and a root package.json dependency change propose nothing"
HEAD1=$(git rev-parse --short=10 HEAD); mk "Commands" "package.json"
echo 'lock2' > pnpm-lock.yaml; echo '{"name":"root","dependencies":{"y":"2"}}' > package.json; git commit -qam "root dep + lock modified"
ck '^fresh Commands' root-dep-fresh check "$P" "${G[@]}"; echo "$LAST" | grep -q propose-init && { fail=$((fail+1)); echo "FAIL propose-init on a dependency add"; } || pass=$((pass+1))
echo "# root package.json scripts change -> Commands stale only, no propose-init"
echo '{"name":"root","scripts":{"dev":"turbo dev"}}' > package.json; git commit -qam "root scripts"
ck '^stale Commands :: M package.json (scripts changed)' root-scripts check "$P" "${G[@]}"; echo "$LAST" | grep -q propose-init && { fail=$((fail+1)); echo "FAIL propose-init on a scripts change"; } || pass=$((pass+1))
echo "# config file under a watch glob (any change) -> stale"
HEAD1=$(git rev-parse --short=10 HEAD); mk "Web config" "apps/web/*.config.*"
echo 'c' > apps/web/next.config.ts; git add -A; git commit -qm "add config"; HEAD1=$(git rev-parse --short=10 HEAD); mk "Web config" "apps/web/*.config.*"
echo 'c2' >> apps/web/next.config.ts; git commit -qam "modify config"
ck '^stale Web config :: M apps/web/next.config.ts (config file)' config-M check "$P" "${G[@]}"
echo "# workspace config change -> propose-init"
HEAD1=$(git rev-parse --short=10 HEAD); mk "X" "nothing/**"
echo 'packages: [apps/*]' > pnpm-workspace.yaml; git add -A; git commit -qm "workspace"
ck '^propose-init :: workspace config changed: pnpm-workspace.yaml' workspace check "$P" "${G[@]}"
echo "# lockfile TYPE change (package-manager switch) -> propose-init"
HEAD1=$(git rev-parse --short=10 HEAD); mk "X" "nothing/**"
git rm -q pnpm-lock.yaml; echo '{}' > package-lock.json; git add -A; git commit -qm "switch to npm"
ck '^propose-init :: lockfile type changed (package manager switch): pnpm-lock.yaml -> package-lock.json' lock-switch check "$P" "${G[@]}"
echo "# new top-level app -> propose-init"
HEAD1=$(git rev-parse --short=10 HEAD); mk "X" "nothing/**"
mkdir -p apps/mobile/src; echo m > apps/mobile/src/m.ts; git add -A; git commit -qm "new app"
ck '^propose-init :: new top-level app/package: apps/mobile' newapp check "$P" "${G[@]}"
echo "# a new profile works without a script edit (--profiles dir with a made-up ecosystem)"
mkdir -p "$S/prof2"; printf 'dt:config-files: foo.toml\ndt:app-roots: crates\n' > "$S/prof2/rust.md"
HEAD1=$(git rev-parse --short=10 HEAD); mk "Rust cfg" "crates/**"
mkdir -p crates/a; echo x > crates/a/foo.toml; git add -A; git commit -qm "crate"; HEAD1=$(git rev-parse --short=10 HEAD); mk "Rust cfg" "crates/**"
echo y >> crates/a/foo.toml; git commit -qam "foo.toml modified"
ck '^stale Rust cfg :: M crates/a/foo.toml (config file)' newprofile check "$P" "${G[@]}" --profiles "$S/prof2"
ck '^fresh Rust cfg' newprofile-absent check "$P" "${G[@]}" --profiles "$S/empty"
echo "$LAST" | grep -q '^note :: no profile rules found' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL no-profile note"; }
HEAD1=$(git rev-parse --short=10 HEAD); mk "Rust cfg" "crates/**"
mkdir -p crates/b; echo z > crates/b/x.rs; git add -A; git commit -qm "new crate"
ck '^propose-init :: new top-level app/package: crates/b' newprofile-approot check "$P" "${G[@]}" --profiles "$S/prof2"

echo "# unknown sha -> stale; guard.json input works"
printf '## Y\nchecked: deadbeef00 · 2026-01-01 · watch: apps/**\n' > "$P"
ck '^stale Y :: checked sha deadbeef00 not found' badsha check "$P" "${G[@]}"
printf '{"repo_root":"%s","base_branch":"main"}' "$R" > "$S/guard.json"
ck '^stale Y' guardjson check "$P" --guard "$S/guard.json"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
