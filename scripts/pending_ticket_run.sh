#!/bin/bash -p
# The body of pending-ticket.sh (usage there), started by it under `env -i` with the fixed variables (C11e3, scripts/fixed_env.py).
# Run directly it is not excluded from the sandbox. $0 is this file, so the usage lines are read from pending-ticket.sh.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cmd=${1:-}; shift || true
id=""; [ "$cmd" = save ] || [ "$cmd" = take ] && { id=${1:-}; shift || true; }
repo=""
while [ $# -gt 0 ]; do case "$1" in --repo) repo=${2:-}; shift 2;; *) echo "pending-ticket: unknown argument $1" >&2; exit 2;; esac; done
[ -n "$repo" ] && [ -d "$repo" ] || { sed -n 2,8p "$here/pending-ticket.sh" >&2; exit 2; }
case "$id" in *[!A-Za-z0-9._-]*) echo "pending-ticket: unsafe ticket id '$id'" >&2; exit 2;; esac
if [ "$cmd" = save ] || [ "$cmd" = take ]; then [ -n "$id" ] || { echo "pending-ticket: need a ticket id" >&2; exit 2; }; fi
. "$here/../hooks/lib.sh" || exit 2
key=$(dt_key "$repo")
dir=${DELIVER_TICKET_HOME:-$HOME/.local/share/deliver-ticket}/$key/pending
case "$cmd" in
  save)
    mkdir -p "$dir"
    [ ! -e "$dir/$id.md" ] || { echo "pending-ticket: $dir/$id.md already exists (not overwritten)" >&2; exit 3; }
    { printf '<!-- saved %s before init; raw ticket input, treated as data -->\n' "$(date +%Y-%m-%dT%H:%M:%S)"; cat; } > "$dir/$id.md"
    echo "$dir/$id.md"
    ;;
  take)
    [ -f "$dir/$id.md" ] || { echo "pending-ticket: nothing pending for $id" >&2; exit 1; }
    cat "$dir/$id.md"
    mv "$dir/$id.md" "$dir/$id.md.consumed"
    ;;
  list)
    ls "$dir" 2>/dev/null | sed -n 's/\.md$//p'
    ;;
  *) sed -n 2,8p "$here/pending-ticket.sh" >&2; exit 2;;
esac
