#!/bin/bash
# Print the KEY NAMES of an env file, never the values. Usage: env-keys.sh <file>
# The only sanctioned way for the skill to learn what an env file contains.
set -u
f=${1:-}
[ -n "$f" ] || { echo "usage: env-keys.sh <env-file>" >&2; exit 2; }
case "$(basename "$f")" in .env*) ;; *) echo "env-keys.sh: only .env* files (got $(basename "$f"))" >&2; exit 2;; esac
[ -f "$f" ] || { echo "env-keys.sh: no such file: $f" >&2; exit 1; }
# sed prints only the captured name; the rest of the line is never output.
# The trailing echo + blank-line filter make the output end in a newline even when the file's last line has none.
{ sed -n 's/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*/\2/p' "$f"; echo; } | sed '/^$/d'
