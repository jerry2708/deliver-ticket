#!/bin/bash
# See scripts/plan_hash.py. Read-only: the short hash of the ticket's ## Plan section, shown to the user under the plan (stage 2). NOT excluded from the sandbox; allow rule, no prompt.
exec python3 -I "$(dirname "$0")/plan_hash.py" "$@"
