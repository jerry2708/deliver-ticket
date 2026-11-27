#!/bin/bash
# Key-looking strings in a ticket's evidence and diff, masked (stages 4 and 6). See scripts/secret_scan.py. Read-only.
#   secret-scan.sh <ID> --guard <state>/guard.json      exit 0 nothing found, 1 findings, 2 error
# NOT excluded from the sandbox; allow rule, no prompt (install_hooks.SANDBOXED). C11h: a credential-pattern grep on the state dir prompted (DRY-02).
exec python3 -I "$(dirname "$0")/secret_scan.py" "$@"
