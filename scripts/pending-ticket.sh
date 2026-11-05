#!/bin/bash
# Keep the input of a ticket that was started before the project was initialised, so init can run and the ticket
# then continues at stage 0 without the user pasting it again.
#   pending-ticket.sh save <ID> --repo <repo>   # raw ticket input on stdin -> <state>/pending/<ID>.md (refuses to overwrite)
#   pending-ticket.sh take <ID> --repo <repo>   # prints it and renames the file to <ID>.md.consumed (nothing is deleted)
#   pending-ticket.sh list --repo <repo>        # pending IDs
# <state> = ~/.local/share/deliver-ticket/<project-key>/ (DELIVER_TICKET_HOME overrides the root). A state dir without
# guard.json is "not initialised" for the hooks, so saving here changes no hook behaviour.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cmd=${1:-}; shift || true
id=""; [ "$cmd" = save ] || [ "$cmd" = take ] && { id=${1:-}; shift || true; }
repo=""
while [ $# -gt 0 ]; do case "$1" in --repo) repo=${2:-}; shift 2;; *) echo "pending-ticket: unknown argument $1" >&2; exit 2;; esac; done
[ -n "$repo" ] && [ -d "$repo" ] || { sed -n 2,8p "$0" >&2; exit 2; }
case "$id" in *[!A-Za-z0-9._-]*) echo "pending-ticket: unsafe ticket id '$id'" >&2; exit 2;; esac
if [ "$cmd" = save ] || [ "$cmd" = take ]; then [ -n "$id" ] || { echo "pending-ticket: need a ticket id" >&2; exit 2; }; fi
. "$here/../hooks/lib.sh"
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
  *) sed -n 2,8p "$0" >&2; exit 2;;
esac
