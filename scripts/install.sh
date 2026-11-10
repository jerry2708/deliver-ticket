#!/bin/bash
# Install the deliver-ticket hooks on this machine (user level). Run it from the clone: ~/.claude/skills/deliver-ticket/scripts/install.sh
# 1. checks the tools and that this clone sits at exactly ~/.claude/skills/deliver-ticket (the hooks use that path)
# 2. prints the settings.json diff, asks y/n, and only on "y" applies it (install-hooks.sh makes a backup), then runs `status`
# 3. prints the per-project init reminder (init is run per project, in the main checkout, inside Claude Code)
# Never writes without a "y" read from stdin (no tty, no input, anything but y/Y = nothing written).
# Reads HOME for ~/.claude/settings.json (tests use a fake HOME).
set -u
SK=$(cd "$(dirname "$0")/.." && pwd -P)
WANT="$HOME/.claude/skills/deliver-ticket"
MIN_CLAUDE=2.1.311
err=0

need() { command -v "$1" >/dev/null 2>&1 && echo "ok   $1 ($(command -v "$1"))" || { echo "MISSING $1 (required)"; err=1; }; }
echo "== tools"
need git; need python3; need bash
if command -v glab >/dev/null 2>&1; then echo "ok   glab (optional: MR creation at the stop points that need it)"; else echo "note glab not found (optional; only needed for stop points that create a GitLab MR)"; fi
if command -v claude >/dev/null 2>&1; then
  v=$(claude --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [ -n "$v" ] && [ "$(printf '%s\n%s\n' "$MIN_CLAUDE" "$v" | sort -V | head -1)" = "$MIN_CLAUDE" ]; then echo "ok   claude $v (tested minimum $MIN_CLAUDE)"
  else echo "WARNING claude version '${v:-unknown}' is below the tested minimum $MIN_CLAUDE (the hooks and stages were tested on $MIN_CLAUDE)"; fi
else echo "WARNING claude not found on PATH (install Claude Code, minimum $MIN_CLAUDE)"; fi

echo "== clone path"
if [ "$(cd "$WANT" 2>/dev/null && pwd -P)" = "$SK" ]; then echo "ok   $SK"
else echo "WRONG PATH: this clone is at $SK; clone it to exactly $WANT (the hooks and SKILL.md use that path)"; err=1; fi
[ $err = 0 ] || { echo "Fix the above, then run this script again. Nothing was written."; exit 1; }

echo "== settings diff (user level: $HOME/.claude/settings.json)"
"$SK/scripts/install-hooks.sh" diff || { echo "install-hooks.sh diff failed. Nothing was written."; exit 1; }
printf 'Apply this to %s (a backup is made next to it)? [y/N] ' "$HOME/.claude/settings.json"
ans=""; read -r ans || true
case "$ans" in
  y|Y) ;;
  *) echo; echo "Nothing written."; exit 0 ;;
esac
"$SK/scripts/install-hooks.sh" apply --confirmed || { echo "apply failed; run: $SK/scripts/install-hooks.sh status"; exit 1; }
"$SK/scripts/install-hooks.sh" status || exit 1
cat <<EOF

Next, per project (state is per machine, under the state root, not in this repo):
  cd <the project's main checkout>, start Claude Code, run:  /deliver-ticket init
Rollback: $SK/scripts/install-hooks.sh uninstall --confirmed (README "Emergency: a hook blocks every session").
EOF
