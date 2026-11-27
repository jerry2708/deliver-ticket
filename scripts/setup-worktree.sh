#!/bin/bash
# Prepare a freshly created ticket worktree. Usage: setup-worktree.sh <repo-root> <worktree> <ticket-id>
# Reads guard.json from the state dir. Env files are symlinked, never copied or read.
# Prints the port block (VAR=port lines) on stdout and records it in <state>/ports/<ID>. Creates <state>/evidence/<ID>/ (not for _base).
set -eu
root=$1; wt=$2; id=$3
# same check as hooks/worktree-create.sh: the id becomes a path segment ($state/evidence/$id, $state/ports/$id); `_base` passes (`_` is allowed)
case "$id" in ""|*[!A-Za-z0-9._-]*|.*) echo "setup-worktree: unsafe or empty ticket id '$id'" >&2; exit 1;; esac
here=$(cd "$(dirname "$0")" && pwd)
DT_HOME=${DELIVER_TICKET_HOME:-$HOME/.local/share/deliver-ticket}
p=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir); p=${p%/.git}
key=$(printf '%s-%s' "$(basename "$p")" "$(printf '%s' "$p" | shasum -a 1 | cut -c1-8)")
state=$DT_HOME/$key
g=$state/guard.json
[ -f "$g" ] || { echo "setup-worktree: no guard.json at $g" >&2; exit 1; }
py() { python3 -I -c "$1" "$g"; }

# 1. env files: ln -s from the main checkout (names from guard.json, relative, no ..)
py 'import json,sys; [print(x) for x in json.load(open(sys.argv[1])).get("env_files",[])]' | while IFS= read -r rel; do
  case "$rel" in /*|*..*) echo "setup-worktree: skipping unsafe env file name '$rel'" >&2; continue;; esac
  src=$root/$rel; dst=$wt/$rel
  # `[ -e ]` cannot tell the two causes apart: inside the sandbox the project denyRead `<repo>/.env*` (C11h) hides an existing file
  # (stage 4 `_base` setup, stage 1b 2b); from the WorktreeCreate hook (unsandboxed) the file is really missing.
  if [ ! -e "$src" ]; then echo "setup-worktree: env file $rel not visible - not linked (inside the sandbox: hidden by denyRead .env*, by design, C11h; outside it: not in the main checkout)" >&2; continue; fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then continue; fi
  mkdir -p "$(dirname "$dst")" && ln -s "$src" "$dst" && echo "linked env file: $rel" >&2
done

# 2. dependencies
inst=$(py 'import json,sys; print(json.load(open(sys.argv[1])).get("install") or "")')
if [ -n "$inst" ]; then echo "install: $inst" >&2; (cd "$wt" && sh -c "$inst") >&2; fi

# <ticket-id> _base (the shared base worktree of base-worktree.sh, stage 4; no ticket ID starts with `_`): env links and install only, no port block
[ "$id" = _base ] && exit 0

# 3. the ticket's evidence dir (C11i): stage 3 writes `<cmd> > <state>/evidence/<ID>/stage3-*.txt` in one plain call, which fails on a
# missing dir (DRY-03). Created here because both worktree paths run this script with no extra prompt (the hook; stage 1b 2b).
mkdir -p "$state/evidence/$id"

# 4. port block: lowest free slot, recorded per ticket (ports are not secrets)
mkdir -p "$state/ports"
# mkdir is atomic: only one setup at a time picks a slot (stale lock after ~15s => stop, never break it silently)
n=0; until mkdir "$state/ports/.lock" 2>/dev/null; do
  n=$((n+1)); [ $n -gt 150 ] && { echo "setup-worktree: port lock $state/ports/.lock held >15s; if no setup is running remove it by hand" >&2; exit 1; }
  sleep 0.1
done
trap 'rmdir "$state/ports/.lock" 2>/dev/null' EXIT
read -r base step vars < <(py 'import json,sys; p=json.load(open(sys.argv[1]))["ports"]; print(p["base"],p["step"]," ".join(p["vars"]))') || true
if [ -n "${vars:-}" ]; then
  if [ -f "$state/ports/$id" ]; then cat "$state/ports/$id"; exit 0; fi
  slot=0; while grep -qs "^# slot $slot\$" "$state"/ports/* 2>/dev/null; do slot=$((slot+1)); done
  { echo "# slot $slot"; i=0; for v in $vars; do echo "$v=$((base + step*slot + i))"; i=$((i+1)); done; } > "$state/ports/$id"
  cat "$state/ports/$id"
fi
