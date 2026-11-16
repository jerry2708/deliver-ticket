#!/bin/bash
# See scripts/git_push.py. The gate action that pushes: excluded from the sandbox, with a permission ask rule on this path (the user's yes).
exec python3 -I "$(dirname "$0")/git_push.py" "$@"
