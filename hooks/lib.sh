# Shared by every deliver-ticket hook (sourced, not executed).
# Hooks are user-level, so they run in every repo: the no-state check below is the
# cheap first step of each hook and must stay free of python and jq.
#
# After `dt_init`: PAYLOAD (raw stdin), DT_HOME (state root), DT_KEY, DT_STATE (project
# state dir), DT_DIR (hooks dir). Returns 1 when this repo has no delivery state.

DT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DT_HOME=${DELIVER_TICKET_HOME:-$HOME/.local/share/deliver-ticket}

dt_block() { printf 'deliver-ticket: %s\n' "$*" >&2; exit 2; }

# Project key = <basename>-<first 8 hex of sha1 of the repo path>; same in every worktree.
dt_key() {
  local common p
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  p=${common%/.git}
  printf '%s-%s' "$(basename "$p")" "$(printf '%s' "$p" | shasum -a 1 | cut -c1-8)"
}

dt_init() {
  PAYLOAD=$(cat)
  local cwd
  cwd=$(printf '%s' "$PAYLOAD" | sed -n 's/.*"cwd" *: *"\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$cwd" ] && [ -d "$cwd" ] || cwd=$PWD
  DT_KEY=$(dt_key "$cwd") || return 1
  DT_STATE=$DT_HOME/$DT_KEY
  # No guard.json = never initialised (or init still running): nothing to guard.
  [ -f "$DT_STATE/guard.json" ] || return 1
  return 0
}

# Repo without delivery state: nothing to guard, except the state root itself, which is protected in every repo and cwd
# (review finding A2). Cheap text prefilter first, no python: only a payload that names the state root's directory name
# (the basename of DT_HOME as configured and as resolved, a substring of every absolute, ~, $HOME and relative spelling,
# and the payload carries cwd) starts the core, mode `nostate` (protected_state only, never reads guard.json). Fail-closed
# through dt_core. Known limits: a path never spelled with the root's name (globs, variables, interpreters).
dt_nostate() {
  local b1 b2 phys sk pl hit=0
  # The default root's name is the skill's own directory name: take the skill dir's path out of the text first, or every
  # skill script call (and every command run with the skill repo as cwd) would be a hit. `<skill dir>/../..` spellings
  # keep the rest of the text, so they still match.
  sk=$(cd "$DT_DIR/.." && pwd -P)
  pl=${PAYLOAD//"$sk"/}
  [ -n "$HOME" ] && pl=${pl//"~${sk#"$HOME"}"/}
  b1=${DT_HOME%/}; b1=${b1##*/}
  case "$pl" in *"$b1"*) hit=1 ;; esac
  if [ $hit = 0 ]; then
    phys=$(cd "$DT_HOME" 2>/dev/null && pwd -P)
    b2=${phys##*/}
    [ -n "$b2" ] && case "$pl" in *"$b2"*) hit=1 ;; esac
  fi
  [ $hit = 1 ] || return 0
  DT_STATE=""
  dt_core nostate
}

# Run the python core for hook mode $1. A crash or any code other than 0/2 blocks:
# exit 1 from a hook is a non-blocking error in Claude Code.
dt_core() {
  local mode=$1 rc
  printf '%s' "$PAYLOAD" | DT_STATE_DIR=$DT_STATE DT_HOME=$DT_HOME python3 -I "$DT_DIR/dtcore.py" "$mode"
  rc=$?
  [ $rc -eq 0 ] && return 0
  [ $rc -eq 2 ] && exit 2
  dt_block "hook core failed (exit $rc) - blocking (fail-closed)"
}
